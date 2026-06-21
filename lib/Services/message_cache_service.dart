import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../Model/chat_model.dart';

/// 消息持久化缓存服务
/// 使用 JSON 文件存储聊天记录，按设备 IP 分文件
class MessageCacheService {
  static final MessageCacheService _instance = MessageCacheService._();
  factory MessageCacheService() => _instance;
  MessageCacheService._();

  String? _cacheDir;

  /// 每个设备的写入锁，防止并发读写导致的竞态条件
  final Map<String, Future<void>> _writeLocks = {};

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

  /// 获取某设备的消息缓存文件路径
  String _getCacheFilePath(String deviceId) {
    // 用设备 IP 的 MD5 简化作为文件名
    final safeName = deviceId.replaceAll('.', '_').replaceAll(':', '_');
    return '$_cacheDir/${safeName}_messages.json';
  }

  /// 保存消息列表到缓存
  Future<void> saveMessages(String deviceId, List<ChatMessage> messages) async {
    try {
      await _getCacheDir();
      await _writeMessages(deviceId, messages);
    } catch (e) {
      debugPrint('消息缓存保存失败: $e');
    }
  }

  /// 从缓存读取消息列表
  Future<List<ChatMessage>> loadMessages(String deviceId) async {
    try {
      await _getCacheDir();
      final filePath = _getCacheFilePath(deviceId);
      final file = File(filePath);
      if (!await file.exists()) return [];

      final content = await file.readAsString();
      final jsonList = jsonDecode(content) as List<dynamic>;
      return jsonList
          .map((j) => ChatMessage.fromJson(j as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('消息缓存读取失败: $e');
      return [];
    }
  }

  /// 追加一条消息到缓存
  Future<void> appendMessage(String deviceId, ChatMessage message) async {
    await _withLock(deviceId, () async {
      try {
        final messages = await loadMessages(deviceId);
        messages.add(message);
        // 最多保留 500 条消息
        if (messages.length > 500) {
          messages.removeRange(0, messages.length - 500);
        }
        await _writeMessages(deviceId, messages);
      } catch (e) {
        debugPrint('消息缓存追加失败: $e');
      }
    });
  }

  /// 更新某条消息（带锁，防止并发写入导致的竞态条件）
  Future<void> updateMessage(
      String deviceId, String messageId, ChatMessage updatedMessage) async {
    await _withLock(deviceId, () async {
      try {
        final messages = await loadMessages(deviceId);
        final index = messages.indexWhere((m) => m.id == messageId);
        if (index != -1) {
          messages[index] = updatedMessage;
          await _writeMessages(deviceId, messages);
        }
      } catch (e) {
        debugPrint('消息缓存更新失败: $e');
      }
    });
  }

  /// 写入消息列表（不加锁的内部方法）
  Future<void> _writeMessages(String deviceId, List<ChatMessage> messages) async {
    final filePath = _getCacheFilePath(deviceId);
    final file = File(filePath);
    final jsonList = messages.map((m) => m.toJson()).toList();
    await file.writeAsString(jsonEncode(jsonList));
  }

  /// 串行化写入操作，避免竞态条件
  Future<void> _withLock(String deviceId, Future<void> Function() action) async {
    // 等待前一个写入完成
    final previous = _writeLocks[deviceId];
    if (previous != null) {
      await previous;
    }
    // 执行当前写入
    final future = action();
    _writeLocks[deviceId] = future;
    await future;
  }

  /// 清空某设备的消息缓存（给 chat_info_page 使用）
  Future<void> clearMessagesForDevice(String deviceId) async {
    return clearMessages(deviceId);
  }

  /// 清空某设备的消息缓存
  Future<void> clearMessages(String deviceId) async {
    try {
      await _getCacheDir();
      final filePath = _getCacheFilePath(deviceId);
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      debugPrint('消息缓存清空失败: $e');
    }
  }

  /// 清空所有消息缓存
  Future<void> clearAllMessages() async {
    try {
      await _getCacheDir();
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
