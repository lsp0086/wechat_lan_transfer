import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../Model/device_info.dart';
import 'message_cache_service.dart';

/// E1：设备列表的本地缓存。从 ChatListPage 抽出的纯文件读写，
/// 原子写入（先 .tmp 再 rename），读取时逐条容错。
class DeviceListStore {
  DeviceListStore({MessageCacheService? cache})
    : _cache = cache ?? MessageCacheService();

  final MessageCacheService _cache;

  Future<String> _filePath() async =>
      '${await _cache.getCacheDir()}/device_list.json';

  /// 原子写入。临时文件不完整则放弃，不覆盖旧缓存。
  Future<void> save(List<DeviceInfo> devices) async {
    final filePath = await _filePath();
    final tempPath = '$filePath.tmp';
    try {
      final jsonStr = jsonEncode(devices.map((d) => d.toJson()).toList());
      final tempFile = File(tempPath);
      await tempFile.writeAsString(jsonStr, flush: true);
      if (!await tempFile.exists() || await tempFile.length() < jsonStr.length) {
        debugPrint('[DeviceListStore] 临时文件不完整，放弃本次保存');
        return;
      }
      await tempFile.rename(filePath);
    } catch (e) {
      debugPrint('[DeviceListStore] 保存失败: $e');
      try {
        final temp = File(tempPath);
        if (await temp.exists()) await temp.delete();
      } catch (_) {}
    }
  }

  /// 读取。主文件缺失时尝试从残留 .tmp 还原；单条损坏只丢弃该条。
  Future<List<DeviceInfo>> load() async {
    try {
      final filePath = await _filePath();
      final file = File(filePath);
      final tempFile = File('$filePath.tmp');
      if (!await file.exists() && await tempFile.exists()) {
        try {
          await tempFile.rename(file.path);
        } catch (_) {}
      }
      if (!await file.exists()) return [];
      final content = await file.readAsString();
      if (content.trim().isEmpty) return [];
      final jsonList = jsonDecode(content) as List<dynamic>;
      final result = <DeviceInfo>[];
      for (final entry in jsonList) {
        try {
          if (entry is Map<String, dynamic>) {
            result.add(DeviceInfo.fromJson(entry));
          }
        } catch (e) {
          debugPrint('[DeviceListStore] 跳过损坏记录: $e');
        }
      }
      return result;
    } catch (e) {
      debugPrint('[DeviceListStore] 读取失败: $e');
      return [];
    }
  }
}
