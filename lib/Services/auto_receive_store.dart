// E1：自动接收配置存储。从 ChatListPage 抽出的文件读写模块（无页面状态，可单测）。
// P0-S7：deviceIp -> bool，缺省 false；持久化在 auto_receive_config.json。

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'app_config_store.dart';

class AutoReceiveStore {
  final Map<String, bool> config = {};

  /// 读盘合并（文件损坏/不存在时保留内存缺省，不抛错）。
  Future<void> load() async {
    try {
      final content = await AppConfigStore.read(AppConfigStore.autoReceiveFile);
      if (content == null || content.isEmpty) return;
      final json = jsonDecode(content) as Map<String, dynamic>;
      config.clear();
      for (final entry in json.entries) {
        config[entry.key] = entry.value as bool;
      }
    } catch (e) {
      debugPrint('[AutoReceiveStore] 加载失败: $e');
    }
  }

  /// 缺省 false，已显式配置的值不变。
  bool get(String deviceIp) => config[deviceIp] ?? false;

  /// 设置并持久化（合并已有字段，原子写）。
  Future<void> set(String deviceIp, bool value) async {
    config[deviceIp] = value;
    try {
      Map<String, dynamic> json = {};
      final content = await AppConfigStore.read(AppConfigStore.autoReceiveFile);
      if (content != null && content.isNotEmpty) {
        json = jsonDecode(content) as Map<String, dynamic>;
      }
      json[deviceIp] = value;
      await AppConfigStore.writeAtomic(
        AppConfigStore.autoReceiveFile,
        jsonEncode(json),
      );
    } catch (e) {
      debugPrint('[AutoReceiveStore] 保存失败: $e');
    }
  }

  /// legacy（IP 键）设备升级为 deviceId 键时迁移配置。
  Future<void> migrate(String oldKey, String newKey) async {
    final old = config.remove(oldKey);
    if (old == null) return;
    config[newKey] = old;
    try {
      await AppConfigStore.writeAtomic(
        AppConfigStore.autoReceiveFile,
        jsonEncode(config),
      );
    } catch (e) {
      debugPrint('[AutoReceiveStore] 迁移失败: $e');
    }
  }
}
