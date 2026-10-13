import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'app_config_store.dart';

/// E1：存储路径与首选端口的读写。从 ChatListPage 抽出，行为不变：
/// 端口只接受 1024–65535，路径为空不写入，写入时合并已有字段。
class StorageConfig {
  const StorageConfig({this.storagePath, this.udpPort, this.tcpPort});

  final String? storagePath;
  final int? udpPort;
  final int? tcpPort;

  static int? _port(dynamic raw) {
    final n = int.tryParse('${raw ?? ''}');
    if (n == null || n < 1024 || n > 65535) return null;
    return n;
  }

  /// E2：纯解析（可单测）。文件不存在/损坏返回空配置，不抛错。
  static StorageConfig parse(String? raw) {
    try {
      if (raw == null || raw.trim().isEmpty) return const StorageConfig();
      final config = jsonDecode(raw) as Map<String, dynamic>;
      final path = config['storagePath'] as String?;
      return StorageConfig(
        storagePath: (path != null && path.isNotEmpty) ? path : null,
        udpPort: _port(config['udpPort']),
        tcpPort: _port(config['tcpPort']),
      );
    } catch (e) {
      debugPrint('[StorageConfig] 解析失败: $e');
      return const StorageConfig();
    }
  }

  static Future<StorageConfig> load() async {
    try {
      final file = File(await AppConfigStore.pathFor(AppConfigStore.storageFile));
      if (!await file.exists()) return const StorageConfig();
      return parse(await file.readAsString());
    } catch (e) {
      debugPrint('[StorageConfig] 读取失败: $e');
      return const StorageConfig();
    }
  }

  /// 合并写回。path 为空则保留原值。
  static Future<void> save({
    String path = '',
    required int udpPort,
    required int tcpPort,
  }) async {
    try {
      final file = File(await AppConfigStore.pathFor(AppConfigStore.storageFile));
      Map<String, dynamic> config = {};
      if (await file.exists()) {
        try {
          config = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        } catch (_) {}
      }
      if (path.isNotEmpty) config['storagePath'] = path;
      config['udpPort'] = udpPort;
      config['tcpPort'] = tcpPort;
      await AppConfigStore.writeAtomic(AppConfigStore.storageFile, jsonEncode(config));
    } catch (e) {
      debugPrint('[StorageConfig] 保存失败: $e');
    }
  }
}

// E1：配置端口回退收敛（有配置用配置，否则沿用当前首选）。
int resolvePort(int? cfg, int fallback) => cfg ?? fallback;
