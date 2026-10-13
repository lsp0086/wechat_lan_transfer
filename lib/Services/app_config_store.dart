import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// P1-9：应用配置统一落到 documents/config/，原子写（tmp + rename）。
/// 启动时把旧路径文件一次性迁入。
class AppConfigStore {
  AppConfigStore._();
  static String? _dir;

  static const blockedFile = 'blocked_devices.json';
  static const pairedFile = 'paired_devices.json';
  static const autoReceiveFile = 'auto_receive_config.json';
  static const storageFile = 'storage_config.json';
  static const securityFile = 'security_config.json';

  // E6：接收 PIN 不落明文。与私钥同一套安全存储（Keychain / Keystore / DPAPI）。
  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );
  static const _pinKey = 'receive_pin';

  static Future<String> configDir() async {
    if (_dir != null) return _dir!;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/config');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _dir = dir.path;
    await _migrateLegacy(docs.path);
    return _dir!;
  }

  static Future<String> pathFor(String name) async {
    final dir = await configDir();
    return '$dir/$name';
  }

  /// P0-S3：仅TLS传输开关（security_config.json 的 tlsOnly，默认 true）。
  /// 读不到/解析失败时返回 true（fail-closed）。
  static Future<bool> getTlsOnly() async {
    try {
      final raw = await read(securityFile);
      if (raw == null || raw.trim().isEmpty) return true;
      final config = jsonDecode(raw) as Map<String, dynamic>;
      final v = config['tlsOnly'];
      if (v is bool) return v;
      return true;
    } catch (e) {
      debugPrint('[AppConfig] 读取 tlsOnly 失败，默认 true: $e');
      return true;
    }
  }

  /// P0-S3：设置仅TLS开关（保留 security_config.json 其他字段如 events）。
  static Future<void> setTlsOnly(bool value) async {
    try {
      Map<String, dynamic> config = {};
      final raw = await read(securityFile);
      if (raw != null && raw.trim().isNotEmpty) {
        try {
          config = jsonDecode(raw) as Map<String, dynamic>;
        } catch (_) {}
      }
      config['tlsOnly'] = value;
      await writeAtomic(securityFile, jsonEncode(config));
    } catch (e) {
      debugPrint('[AppConfig] 保存 tlsOnly 失败: $e');
    }
  }

  /// N5：发现可见性三档（security_config.json 的 visibility，默认 all）。
  /// all=所有人可见 / paired=仅已配对 / stealth=隐身（仅单播回包）。
  /// 兼容旧 stealthMode=true（视为 stealth），读不到默认 all。
  static Future<String> getVisibility() async {
    try {
      final raw = await read(securityFile);
      if (raw == null || raw.trim().isEmpty) return 'all';
      final config = jsonDecode(raw) as Map<String, dynamic>;
      final v = config['visibility'];
      if (v == 'paired' || v == 'stealth' || v == 'all') return v as String;
      if (config['stealthMode'] == true) return 'stealth';
      return 'all';
    } catch (e) {
      debugPrint('[AppConfig] 读取 visibility 失败，默认 all: $e');
      return 'all';
    }
  }

  /// N5：设置发现可见性三档。
  static Future<void> setVisibility(String value) async {
    if (value != 'all' && value != 'paired' && value != 'stealth') return;
    try {
      Map<String, dynamic> config = {};
      final raw = await read(securityFile);
      if (raw != null && raw.trim().isNotEmpty) {
        try {
          config = jsonDecode(raw) as Map<String, dynamic>;
        } catch (_) {}
      }
      config['visibility'] = value;
      config['stealthMode'] = value == 'stealth';
      await writeAtomic(securityFile, jsonEncode(config));
    } catch (e) {
      debugPrint('[AppConfig] 保存 visibility 失败: $e');
    }
  }

  /// U4：隐身模式开关（security_config.json 的 stealthMode，默认 false）。
  /// E6：接收 PIN 已迁入安全存储；此文件只剩开关与事件记录，不再放密钥。
  static Future<bool> getStealthMode() async {
    try {
      final raw = await read(securityFile);
      if (raw == null || raw.trim().isEmpty) return false;
      final config = jsonDecode(raw) as Map<String, dynamic>;
      final v = config['stealthMode'];
      if (v is bool) return v;
      return false;
    } catch (e) {
      debugPrint('[AppConfig] 读取 stealthMode 失败，默认 false: $e');
      return false;
    }
  }

  /// U4：设置隐身模式开关（保留 security_config.json 其他字段）。
  static Future<void> setStealthMode(bool value) async {
    try {
      Map<String, dynamic> config = {};
      final raw = await read(securityFile);
      if (raw != null && raw.trim().isNotEmpty) {
        try {
          config = jsonDecode(raw) as Map<String, dynamic>;
        } catch (_) {}
      }
      config['stealthMode'] = value;
      await writeAtomic(securityFile, jsonEncode(config));
    } catch (e) {
      debugPrint('[AppConfig] 保存 stealthMode 失败: $e');
    }
  }

  static final RegExp _pinPattern = RegExp(r'^\d{4,8}$');

  /// E6：把历史明文 PIN 从 security_config.json 删掉（已写入安全存储之后调用）。
  static Future<void> _stripLegacyPin() async {
    final raw = await read(securityFile);
    if (raw == null || raw.trim().isEmpty) return;
    Map<String, dynamic> config;
    try {
      config = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (config.remove('receivePin') == null) return;
    await writeAtomic(securityFile, jsonEncode(config));
    debugPrint('[AppConfig] E6 已删除明文 PIN 字段');
  }

  /// S2 / E6：接收 PIN（安全存储，空=不启用）。仅 4~8 位数字有效。
  /// 读到历史明文时一次性迁入安全存储并删除明文。
  static Future<String> getReceivePin() async {
    try {
      final stored = await _secure.read(key: _pinKey);
      if (stored != null && _pinPattern.hasMatch(stored)) return stored;
      final raw = await read(securityFile);
      if (raw == null || raw.trim().isEmpty) return '';
      final config = jsonDecode(raw) as Map<String, dynamic>;
      final legacy = config['receivePin'];
      if (legacy is String && _pinPattern.hasMatch(legacy)) {
        await _secure.write(key: _pinKey, value: legacy);
        await _stripLegacyPin();
        return legacy;
      }
      return '';
    } catch (e) {
      debugPrint('[AppConfig] 读取 receivePin 失败，视为未启用: $e');
      return '';
    }
  }

  /// S2 / E6：设置接收 PIN（空字符串=关闭；仅接受 4~8 位数字）。写入安全存储。
  static Future<bool> setReceivePin(String pin) async {
    if (pin.isNotEmpty && !_pinPattern.hasMatch(pin)) return false;
    try {
      if (pin.isEmpty) {
        await _secure.delete(key: _pinKey);
      } else {
        await _secure.write(key: _pinKey, value: pin);
      }
      await _stripLegacyPin();
      return true;
    } catch (e) {
      debugPrint('[AppConfig] 保存 receivePin 失败: $e');
      return false;
    }
  }

  /// 读取 JSON 字符串数组。文件不存在返回空集；内容损坏则抛出，由调用方决定回退。
  static Future<Set<String>> readStringSet(String name) async {
    final file = File(await pathFor(name));
    if (!await file.exists()) return {};
    final content = await file.readAsString();
    if (content.trim().isEmpty) return {};
    return (jsonDecode(content) as List<dynamic>).map((e) => e.toString()).toSet();
  }

  /// 原子写回 JSON 字符串数组。
  static Future<void> writeStringSet(String name, Set<String> values) =>
      writeAtomic(name, jsonEncode(values.toList()));

  static Future<String?> read(String name) async {
    try {
      final file = File(await pathFor(name));
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (e) {
      debugPrint('[AppConfig] 读取 $name 失败: $e');
      return null;
    }
  }

  /// 原子写：先写 .tmp，再通过 .bak 交换，兼容 Windows 无法覆盖 rename。
  static Future<void> writeAtomic(String name, String content) async {
    final path = await pathFor(name);
    final dest = File(path);
    final tmp = File('$path.tmp');
    final backup = File('$path.bak');
    await tmp.writeAsString(content, flush: true);
    try {
      if (await backup.exists()) await backup.delete();
      if (await dest.exists()) await dest.rename(backup.path);
      await tmp.rename(path);
      if (await backup.exists()) await backup.delete();
    } catch (_) {
      if (!await dest.exists() && await backup.exists()) {
        await backup.rename(path);
      }
      rethrow;
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  }

  static Future<void> _migrateLegacy(String docsPath) async {
    // E6：copy 成功后删源，避免双份残留；失败只打日志。
    Future<void> move(String oldPath, String name) async {
      try {
        final src = File(oldPath);
        final dest = File('$_dir/$name');
        if (await dest.exists() || !await src.exists()) return;
        await src.copy(dest.path);
        try {
          await src.delete();
        } catch (_) {}
        debugPrint('[AppConfig] E6 已迁移并删源 $oldPath -> ${dest.path}');
      } catch (e) {
        debugPrint('[AppConfig] 迁移 $name 失败: $e');
      }
    }

    await move('$docsPath/blocked_devices.json', blockedFile);
    // P1-10：配对记录此前遗漏迁移，导致升级后已配对设备每次都被当成
    // 新指纹重新弹配对确认（对齐 LocalSend：配对关系一经确认即持久）。
    await move('$docsPath/paired_devices.json', pairedFile);
    await move('$docsPath/auto_receive_config.json', autoReceiveFile);
    await move('$docsPath/storage_config.json', storageFile);
    await move('$docsPath/security_config.json', securityFile);
    // 旧 storage 曾写在 chat_cache 的上一级
    await move('$docsPath/chat_cache/../storage_config.json', storageFile);
  }
}
