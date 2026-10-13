// E1：缓存维护（缩略图 LRU + 陈旧语音/图片 + 残留 zip 清理）。
// 从 ChatPage 抽出的纯 IO 函数（目录以参数注入，可单测 temp 目录）。

import 'dart:io';

import 'package:flutter/foundation.dart';

import 'transfer_limits.dart';

class CacheMaintenance {
  CacheMaintenance._();

  // E1：文件大小委托（发送前/语音重试预检共用，可单测mock）。
  static Future<int> fileSizeOf(File f) => f.length();

  /// P1-10：缩略图 LRU（超量删最旧），避免无限堆积。
  static Future<void> pruneThumbnails(
    String? dirPath, {
    int maxFiles = kMaxThumbFiles,
  }) async {
    try {
      if (dirPath == null) return;
      final dir = Directory(dirPath);
      if (!await dir.exists()) return;
      final files = await dir
          .list()
          .where((e) => e is File)
          .cast<File>()
          .toList();
      if (files.length <= maxFiles) return;
      final stats = <({File file, DateTime modified})>[];
      for (final f in files) {
        try {
          stats.add((file: f, modified: await f.lastModified()));
        } catch (_) {}
      }
      stats.sort((a, b) => a.modified.compareTo(b.modified));
      final toDelete = stats.length - maxFiles;
      for (var i = 0; i < toDelete; i++) {
        try {
          await stats[i].file.delete();
        } catch (_) {}
      }
      debugPrint('[CacheMaint] 缩略图 LRU 清理: 删除 $toDelete 个');
    } catch (e) {
      debugPrint('[CacheMaint] 缩略图清理失败: $e');
    }
  }

  /// D3：清理 7 天以上语音/图片陈旧缓存，避免无限堆积。
  /// E1：阈值抽至 transfer_limits.kStaleCacheDays。
  static Future<void> cleanupStaleCache(String docPath) async {
    try {
      final now = DateTime.now();
      for (final name in ['thumbnails', 'voice', 'images']) {
        final dir = Directory('$docPath/$name');
        if (!await dir.exists()) continue;
        await for (final entity in dir.list()) {
          if (entity is! File) continue;
          try {
            final modified = await entity.lastModified();
            if (now.difference(modified).inDays >= kStaleCacheDays) {
              await entity.delete();
            }
          } catch (_) {}
        }
      }
      debugPrint('[CacheMaint] D3 陈旧语音/图片缓存(7天)清理完成');
    } catch (e) {
      debugPrint('[CacheMaint] D3 陈旧缓存清理失败: $e');
    }
  }

  /// P1-10：清理 temp 下超过 24h 的残留 zip（打包中断/发送异常残留）。
  /// E1：阈值抽至 transfer_limits.kStaleTempZipHours。
  static Future<void> cleanupStaleTempZips(String tempPath) async {
    try {
      final dir = Directory(tempPath);
      if (!await dir.exists()) return;
      final now = DateTime.now();
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final path = entity.path.toLowerCase();
        if (!path.endsWith('.zip')) continue;
        try {
          final modified = await entity.lastModified();
          if (now.difference(modified).inHours >= kStaleTempZipHours) {
            await entity.delete();
            debugPrint('[CacheMaint] 清理陈旧临时 zip: ${entity.path}');
          }
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[CacheMaint] 临时 zip 清理失败: $e');
    }
  }
}
