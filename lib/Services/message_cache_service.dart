import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as pth;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:synchronized/synchronized.dart';
import '../Model/chat_model.dart';
import 'cache_crypto.dart';

/// 消息持久化缓存服务
/// E3：存储后端迁 sqlite（对标 LocalSend 大历史）——真增量写（事务批量
/// upsert，不再整文件 JSON 重写）+ 按 seq 分页读取。
/// 内存缓存 + 400ms 防抖落盘 + 写锁结构不变；sqlite 打开失败（Linux 桌面
/// 无 libsqlite3 等环境）自动降级 JSON 文件（原路径保留为回退）。
/// P0-7：身份键 = 对端 deviceId（TLS 指纹）；旧端无 deviceId 时回退 IP（legacy）
class MessageCacheService {
  static final MessageCacheService _instance = MessageCacheService._internal();
  factory MessageCacheService() => _instance;
  MessageCacheService._internal();

  /// 测试用：独立实例（不进单例），缓存目录注入临时路径。
  factory MessageCacheService.forTest(String dir) {
    final s = MessageCacheService._internal();
    s._cacheDir = dir;
    return s;
  }

  String? _cacheDir;
  // E3：sqlite 后端（懒打开）；打开失败降级 JSON 文件路径。
  Database? _db;
  bool _useSqlite = true;
  // E3-遗留：落盘加密密钥（懒加载；空串=降级明文）。
  String? _cacheKey;

  /// 每个设备的写入锁（E3/新库：synchronized Lock 替换手写 future 链，
  /// 防异常时 gate 残留导致后续串行；语义不变：同设备读写串行化）。
  final Map<String, Lock> _writeLocks = {};

  /// 内存缓存：deviceId -> 消息列表，避免每次操作都读文件
  final Map<String, List<ChatMessage>> _memoryCache = {};
  // E3：合并短时间内的多次落盘，传输进度更新不再每条都重写。
  final Map<String, Timer> _flushTimers = {};
  static const Duration _flushDelay = Duration(milliseconds: 400);

  /// 缓存最大容量（E3：对标 LocalSend 大历史）
  static const int _maxCacheSize = 2000;

  /// 初始化缓存目录
  Future<String> getCacheDir() async {
    return _getCacheDir();
  }

  Future<String> _getCacheDir() async {
    if (_cacheDir != null) return _cacheDir!;
    try {
      final appDir = await getApplicationDocumentsDirectory();
      _cacheDir = '${appDir.path}/chat_cache';
      final dir = Directory(_cacheDir!);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    } catch (e) {
      // 降级：使用临时目录
      _cacheDir = '${Directory.systemTemp.path}/wechat_lan_chat_cache';
      final dir = Directory(_cacheDir!);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    }
    return _cacheDir!;
  }

  /// P0-7：统一身份键解析入口——有 deviceId（持久指纹）用 deviceId，
  /// 旧端无 deviceId 时回退 IP（legacy 兼容路径）
  static String cacheKeyFor({String? deviceId, required String ip}) {
    return (deviceId != null && deviceId.isNotEmpty) ? deviceId : ip;
  }

  /// P0-7：旧键缓存一次性迁移为 deviceId 键（sqlite 行迁移 / JSON 文件重命名）。
  /// 新键已有数据时不动（避免覆盖新数据）。
  Future<void> migrateLegacyCache(String deviceId, String legacyIp) async {
    try {
      if (deviceId.isEmpty || legacyIp.isEmpty || deviceId == legacyIp) return;
      _memoryCache.remove(legacyIp);
      if (_useSqlite) {
        final db = await _safeOpenDb();
        if (db == null) return;
        final hasNew = db
            .select('SELECT 1 FROM messages WHERE device_key = ? LIMIT 1', [
              deviceId,
            ])
            .isNotEmpty;
        final hasOld = db
            .select('SELECT 1 FROM messages WHERE device_key = ? LIMIT 1', [
              legacyIp,
            ])
            .isNotEmpty;
        if (hasOld && !hasNew) {
          db.execute(
            'UPDATE messages SET device_key = ? WHERE device_key = ?',
            [deviceId, legacyIp],
          );
          debugPrint('[MessageCache] P0-7 sqlite 缓存已迁移: $legacyIp -> $deviceId');
        }
        return;
      }
      await _getCacheDir();
      final newFile = File(_getCacheFilePath(deviceId));
      final oldFile = File(_getCacheFilePath(legacyIp));
      if (await newFile.exists() || !await oldFile.exists()) return;
      await oldFile.rename(newFile.path);
      debugPrint('[MessageCache] P0-7 旧IP缓存已迁移: $legacyIp -> $deviceId');
    } catch (e) {
      debugPrint('[MessageCache] P0-7 缓存迁移失败: $e');
    }
  }

  /// 获取某设备的消息缓存文件路径（JSON 回退后端用）
  String _getCacheFilePath(String deviceId) {
    // 用设备 IP 的 MD5 简化作为文件名
    final safeName = deviceId.replaceAll('.', '_').replaceAll(':', '_');
    return '$_cacheDir/${safeName}_messages.json';
  }

  /// E3-遗留：缓存加密密钥懒加载（失败降级明文，不影响可用性）。
  Future<String> _ensureCacheKey() async {
    final existing = _cacheKey;
    if (existing != null) return existing;
    final key = await loadOrCreateCacheKey();
    _cacheKey = key;
    if (key.isEmpty) {
      debugPrint('[MessageCache] E3 加密密钥不可用，缓存降级明文');
    }
    return key;
  }

  // ================= E3：sqlite 后端 =================

  /// 懒打开 sqlite；失败降级 JSON 文件并返回 null。
  Future<Database?> _safeOpenDb() async {
    if (_db != null) return _db!;
    try {
      final dir = await _getCacheDir();
      final db = sqlite3.open('$dir/messages.db');
      db.execute('''
        CREATE TABLE IF NOT EXISTS messages (
          device_key TEXT NOT NULL,
          id TEXT NOT NULL,
          seq INTEGER NOT NULL,
          payload TEXT NOT NULL,
          PRIMARY KEY (device_key, id)
        )
      ''');
      db.execute(
        'CREATE INDEX IF NOT EXISTS idx_messages_device ON messages(device_key, seq)',
      );
      _db = db;
      await _migrateLegacyJson();
      return _db;
    } catch (e) {
      debugPrint('[MessageCache] E3 sqlite 打开失败，降级 JSON 文件: $e');
      _useSqlite = false;
      return null;
    }
  }

  /// 旧 *_messages.json 一次性导入 sqlite，成功后删源（失败保留，下次再试）。
  /// 文件名曾把 deviceId/IP 的 . 和 : 替换为 _：
  /// 64 位 hex（deviceId）与 4 段全数字（v4 IP）可无损反转；v6/未知保留 JSON，
  /// 运行时 P0-7 迁移（设备上线 rename）后再导。
  Future<void> _migrateLegacyJson() async {
    try {
      final dir = Directory(_cacheDir!);
      if (!await dir.exists()) return;
      final files = await dir.list().toList();
      var imported = 0;
      for (final entity in files) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('_messages.json')) continue;
        // E1/新库：path.basename 跨平台取文件名。
        final name = pth.basename(entity.path);
        final safeKey = name.substring(0, name.length - '_messages.json'.length);
        final deviceKey = _keyFromLegacyName(safeKey);
        if (deviceKey == null) continue;
        try {
          final content = await entity.readAsString();
          final jsonList = jsonDecode(content) as List<dynamic>;
          final messages = jsonList
              .map((j) => ChatMessage.fromJson(j as Map<String, dynamic>))
              .toList();
          await _writeToDb(deviceKey, messages);
          try {
            await entity.delete();
          } catch (_) {}
          imported++;
        } catch (e) {
          debugPrint('[MessageCache] E3 迁移 $name 失败保留: $e');
        }
      }
      if (imported > 0) {
        debugPrint('[MessageCache] E3 已从 JSON 导入 sqlite: $imported 个文件');
      }
    } catch (e) {
      debugPrint('[MessageCache] E3 JSON 迁移扫描失败: $e');
    }
  }

  /// 旧文件名反转为身份键；不可逆返回 null。
  String? _keyFromLegacyName(String safeName) {
    if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(safeName)) return safeName;
    final segs = safeName.split('_');
    if (segs.length == 4 && segs.every((s) => RegExp(r'^\d+$').hasMatch(s))) {
      return segs.join('.');
    }
    return null;
  }

  Future<List<ChatMessage>> _loadFromDb(String deviceId) async {
    final db = (await _safeOpenDb())!;
    final key = await _ensureCacheKey();
    final rows = db.select(
      'SELECT payload FROM messages WHERE device_key = ? ORDER BY seq',
      [deviceId],
    );
    // E3-遗留：`enc1:` 前缀行解密；无前缀历史明文行原样解析（渐进迁移）。
    final out = <ChatMessage>[];
    for (final r in rows) {
      final stored = r['payload'] as String;
      final plain = openPayload(stored, key);
      if (plain == null) {
        debugPrint('[MessageCache] E3 解密失败，跳过一行');
        continue;
      }
      out.add(
        ChatMessage.fromJson(jsonDecode(plain) as Map<String, dynamic>),
      );
    }
    return out;
  }

  /// 事务批量写入（真增量 vs 整文件重写：DELETE + 批量 upsert 在事务内，
  /// 2000 行 ~ms 级；崩溃回滚不留半写）。
  Future<void> _writeToDb(String deviceId, List<ChatMessage> messages) async {
    final db = (await _safeOpenDb())!;
    // E3-遗留：落盘前加密（密钥不可用时 sealPayload 原样返回，即明文降级）。
    final key = await _ensureCacheKey();
    db.execute('BEGIN IMMEDIATE');
    try {
      db.execute('DELETE FROM messages WHERE device_key = ?', [deviceId]);
      final ins = db.prepare(
        'INSERT OR REPLACE INTO messages(device_key, id, seq, payload) '
        'VALUES (?, ?, ?, ?)',
      );
      for (var i = 0; i < messages.length; i++) {
        ins.execute([
          deviceId,
          messages[i].id,
          i,
          sealPayload(jsonEncode(messages[i].toJson()), key),
        ]);
      }
      ins.dispose();
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  // ================= 读写（内存缓存优先，sqlite/JSON 双后端） =================

  /// 保存消息列表到缓存（P1-4：走设备锁，避免与 append 交叉写）
  Future<void> saveMessages(String deviceId, List<ChatMessage> messages) async {
    await _withLock(deviceId, () async {
      try {
        await _getCacheDir();
        _memoryCache[deviceId] = List.from(messages);
        if (_useSqlite) {
          await _writeToDb(deviceId, messages);
        } else {
          await _writeToJsonFile(deviceId, messages);
        }
      } catch (e) {
        debugPrint('消息缓存保存失败: $e');
      }
    });
  }

  /// 从缓存读取消息列表（优先内存缓存；P1-4：走设备锁，避免读到半写入）
  /// D1：分页说明——默认 limit=null 全量兼容；UI 大会话可传 limit 做分页加载。
  Future<List<ChatMessage>> loadMessages(String deviceId, {int? limit}) async {
    return _withLockResult(deviceId, () async {
      if (_memoryCache.containsKey(deviceId)) {
        final all = List<ChatMessage>.from(_memoryCache[deviceId]!);
        if (limit != null && limit >= 0 && all.length > limit) {
          return all.sublist(all.length - limit);
        }
        return all;
      }
      try {
        await _getCacheDir();
        List<ChatMessage> messages;
        if (_useSqlite) {
          messages = await _loadFromDb(deviceId);
        } else {
          messages = await _loadFromJsonFiles(deviceId);
        }
        _memoryCache[deviceId] = messages;
        if (limit != null && limit >= 0 && messages.length > limit) {
          return List<ChatMessage>.from(messages.sublist(messages.length - limit));
        }
        return List.from(messages);
      } catch (e) {
        debugPrint('消息缓存读取失败: $e');
        return <ChatMessage>[];
      }
    });
  }

  /// 锁内读取，避免 load→mutate 再 save 时套两层锁死锁
  Future<List<ChatMessage>> _loadUnlocked(String deviceId) async {
    if (_memoryCache.containsKey(deviceId)) {
      return _memoryCache[deviceId]!;
    }
    await _getCacheDir();
    if (_useSqlite) {
      return _loadFromDb(deviceId);
    }
    return _loadFromJsonFiles(deviceId);
  }

  /// JSON 回退后端读取（原文件路径；E3-遗留：整体 seal 的文件解密，明文兼容）。
  Future<List<ChatMessage>> _loadFromJsonFiles(String deviceId) async {
    final filePath = _getCacheFilePath(deviceId);
    final file = File(filePath);
    if (!await file.exists()) return <ChatMessage>[];
    final content = await file.readAsString();
    final key = await _ensureCacheKey();
    // E3-遗留：enc1: 前缀 → 整体解密后再解析；否则按历史明文 JSON 解析。
    final plain = openPayload(content.trim(), key);
    final jsonList =
        jsonDecode(plain ?? content) as List<dynamic>;
    return jsonList
        .map((j) => ChatMessage.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  /// 追加一条消息到缓存。P1-4：相同 id 已存在则跳过（幂等，防 ChatList/ChatPage 双写）。
  Future<void> appendMessage(String deviceId, ChatMessage message) async {
    await _withLock(deviceId, () async {
      try {
        final messages = await _loadUnlocked(deviceId);
        if (messages.any((m) => m.id == message.id)) {
          debugPrint('[MessageCache] P1-4 幂等跳过: ${message.id}');
          return;
        }
        messages.add(message);
        if (messages.length > _maxCacheSize) {
          messages.removeRange(0, messages.length - _maxCacheSize);
        }
        _memoryCache[deviceId] = messages;
        _scheduleFlush(deviceId);
      } catch (e) {
        debugPrint('消息缓存追加失败: $e');
      }
    });
  }

  /// 更新某条消息（带锁，防止并发写入导致的竞态条件）
  Future<void> updateMessage(
    String deviceId,
    String messageId,
    ChatMessage updatedMessage,
  ) async {
    await _withLock(deviceId, () async {
      try {
        final messages = await _loadUnlocked(deviceId);
        final index = messages.indexWhere((m) => m.id == messageId);
        if (index != -1) {
          messages[index] = updatedMessage;
          _memoryCache[deviceId] = messages;
          _scheduleFlush(deviceId);
        }
      } catch (e) {
        debugPrint('消息缓存更新失败: $e');
      }
    });
  }

  /// E3：退出前把还没落盘的会话立刻写完，避免 400ms 窗口内杀进程丢消息。
  Future<void> flushPending() async {
    final pending = _flushTimers.keys.toList();
    for (final id in pending) {
      _flushTimers.remove(id)?.cancel();
      final messages = _memoryCache[id];
      if (messages == null) continue;
      await _withLock(id, () async {
        if (_useSqlite) {
          await _writeToDb(id, messages);
        } else {
          await _writeToJsonFile(id, messages);
        }
      });
    }
  }

  /// E3：延迟落盘。多次 append/update 合并成一次事务批量写入。
  void _scheduleFlush(String deviceId) {
    _flushTimers[deviceId]?.cancel();
    _flushTimers[deviceId] = Timer(_flushDelay, () {
      _flushTimers.remove(deviceId);
      final messages = _memoryCache[deviceId];
      if (messages == null) return;
      _withLock(deviceId, () async {
        try {
          if (_useSqlite) {
            await _writeToDb(deviceId, messages);
          } else {
            await _writeToJsonFile(deviceId, messages);
          }
        } catch (e) {
          debugPrint('消息缓存落盘失败: $e');
        }
      });
    });
  }

  /// JSON 回退后端写入（原子写：tmp + rename；E3-遗留：整体 seal 落盘）。
  Future<void> _writeToJsonFile(
    String deviceId,
    List<ChatMessage> messages,
  ) async {
    final filePath = _getCacheFilePath(deviceId);
    final tempPath = '$filePath.tmp';
    final tempFile = File(tempPath);
    final key = await _ensureCacheKey();
    final jsonList = messages.map((m) => m.toJson()).toList();
    // E3-遗留：明文 JSON 整体加密（密钥不可用时 sealPayload 原样返回）。
    await tempFile.writeAsString(sealPayload(jsonEncode(jsonList), key));
    await tempFile.rename(filePath);
  }

  /// 串行化同一设备的读写（P1-4：load/save/append/update 共用）
  /// E3/新库：synchronized Lock（异常自动释锁，无残留串行风险）。
  Future<void> _withLock(
    String deviceId,
    Future<void> Function() action,
  ) async {
    await _withLockResult(deviceId, () async {
      await action();
      return null;
    });
  }

  Future<T> _withLockResult<T>(
    String deviceId,
    Future<T> Function() action,
  ) async {
    final lock = _writeLocks.putIfAbsent(deviceId, () => Lock());
    return lock.synchronized(action);
  }

  /// 清空某设备的消息缓存（给 chat_info_page 使用）
  Future<void> clearMessagesForDevice(String deviceId) async {
    return clearMessages(deviceId);
  }

  /// 清空某设备的消息缓存
  Future<void> clearMessages(String deviceId) async {
    await _withLock(deviceId, () async {
      try {
        _memoryCache.remove(deviceId);
        await _getCacheDir();
        if (_useSqlite) {
          final db = await _safeOpenDb();
          if (db != null) {
            db.execute('DELETE FROM messages WHERE device_key = ?', [deviceId]);
          }
        }
        // JSON 回退后端/迁移残留文件一并清理
        final file = File(_getCacheFilePath(deviceId));
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        debugPrint('消息缓存清空失败: $e');
      }
    });
  }

  /// 清空所有消息缓存
  Future<void> clearAllMessages() async {
    try {
      _memoryCache.clear();
      await _getCacheDir();
      if (_useSqlite) {
        final db = await _safeOpenDb();
        if (db != null) {
          db.execute('DELETE FROM messages');
        }
      }
      // JSON 回退后端/迁移残留文件一并清理
      final dir = Directory(_cacheDir!);
      if (await dir.exists()) {
        final files = await dir.list().toList();
        for (final entity in files) {
          if (entity is File) {
            await entity.delete();
          }
        }
      }
    } catch (e) {
      debugPrint('清空所有缓存失败: $e');
    }
  }
}
