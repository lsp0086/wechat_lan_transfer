// E1：文件夹打包/zip 安全逻辑。从 ChatPage 抽出的纯 IO 函数（可单测，temp 目录）。
// P0-6 上限防护（预检 + 兜底跳过）、P0-2/D4 穿越清洗。

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as pth;

/// 打包/解压上限（E1：集中到此，ChatPage 共用）。
class FolderArchiveLimits {
  /// 解压累计大小上限（ZIP 炸弹防护）。
  final int maxExtractTotalSize;
  /// 打包总大小上限。
  final int maxPackTotalSize;
  /// 打包单文件上限（预检拦截 + 打包兜底跳过）。
  final int maxPackSingleFile;
  /// 打包文件数上限。
  final int maxPackFileCount;

  const FolderArchiveLimits({
    this.maxExtractTotalSize = 500 * 1024 * 1024, // 500MB
    this.maxPackTotalSize = 500 * 1024 * 1024, // 500MB
    this.maxPackSingleFile = 200 * 1024 * 1024, // 200MB
    this.maxPackFileCount = 5000,
  });
}

class FolderArchiveService {
  FolderArchiveService._();

  /// 文件夹打包预检：文件数/单文件大小/总大小上限，空目录拒绝。
  /// [describe] 注入大小格式化（UI 文案用，纯逻辑默认字节数）。
  static Future<({bool ok, String message})> checkFolderPackable(
    Directory dir, {
    FolderArchiveLimits limits = const FolderArchiveLimits(),
    String Function(int bytes)? describe,
  }) async {
    String sizeText(int bytes) => describe != null ? describe(bytes) : '$bytes';
    int totalSize = 0;
    int fileCount = 0;
    try {
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        final type = await FileSystemEntity.type(
          entity.path,
          followLinks: false,
        );
        if (type != FileSystemEntityType.file) continue;
        fileCount++;
        if (fileCount > limits.maxPackFileCount) {
          return (
            ok: false,
            message: '文件夹文件过多（>${limits.maxPackFileCount}），请分批发送',
          );
        }
        int size = 0;
        try {
          size = await File(entity.path).length();
        } catch (_) {
          continue;
        }
        if (size > limits.maxPackSingleFile) {
          return (
            ok: false,
            message: '单个文件过大（${sizeText(size)}），请单独发送',
          );
        }
        totalSize += size;
        if (totalSize > limits.maxPackTotalSize) {
          return (
            ok: false,
            message: '文件夹过大（>${sizeText(totalSize)}），请分批发送',
          );
        }
      }
    } catch (e) {
      return (ok: false, message: '文件夹读取失败: $e');
    }
    if (fileCount == 0) {
      return (ok: false, message: '所选文件夹为空');
    }
    return (ok: true, message: '');
  }

  /// 递归将目录中的文件和子目录添加到 zip archive，
  /// 包括空目录以保证文件夹结构完整。
  /// P0-6：单文件上限兜底（预检已拦，异常穿越/增长时此处置空跳过，不 OOM）。
  static Future<void> addDirectoryToArchive(
    Archive archive,
    Directory dir,
    String parentPath, {
    FolderArchiveLimits limits = const FolderArchiveLimits(),
  }) async {
    List<FileSystemEntity> entries;
    try {
      // 使用 followLinks: true，Android FUSE 文件系统上 lstat 行为异常时回退到正常 stat
      entries = await dir.list(recursive: false, followLinks: true).toList();
    } catch (e) {
      debugPrint('[FolderArchive] 无法读取目录 "${dir.path}": $e');
      // 即使读取失败也添加目录条目，保留空目录结构
      archive.add(ArchiveFile('$parentPath/', 0, []));
      return;
    }

    // 先添加当前目录条目，确保空目录也能保留
    archive.add(ArchiveFile('$parentPath/', 0, []));

    for (final entry in entries) {
      // 跨平台获取文件/目录名（E1/新库：path.basename 处理两种分隔符）。
      final name = pth.basename(entry.path);
      // 跳过已知的系统垃圾文件，不盲目过滤所有 . 开头项（Android 数据目录常用）
      const systemSkipFiles = {
        '.DS_Store',
        'Thumbs.db',
        '.thumbnails',
        '.Trashes',
        'ehthumbs.db',
        'desktop.ini',
      };
      if (name.isEmpty || systemSkipFiles.contains(name)) {
        continue;
      }

      // 异步获取文件类型，支持 followLinks 语义
      final eType = await FileSystemEntity.type(entry.path, followLinks: true);
      switch (eType) {
        case FileSystemEntityType.file:
          try {
            // P0-6 兜底：预检后文件若暴涨则跳过，不读入内存
            final statSize = await File(entry.path).length();
            if (statSize > limits.maxPackSingleFile) {
              debugPrint('[FolderArchive] 跳过超大文件 "${entry.path}"');
              continue;
            }
            final fileBytes = await File(entry.path).readAsBytes();
            archive.add(ArchiveFile('$parentPath/$name', fileBytes.length, fileBytes));
          } catch (e) {
            debugPrint('[FolderArchive] 无法读取文件 "${entry.path}": $e');
          }
        case FileSystemEntityType.directory:
          // 显式构造 Directory 而非 entry as Directory，避免 FUSE 下的转型坑
          final subDir = Directory(entry.path);
          if (!await subDir.exists()) {
            debugPrint('[FolderArchive] 子目录不存在 "${entry.path}"，跳过');
            continue;
          }
          await addDirectoryToArchive(
            archive,
            subDir,
            '$parentPath/$name',
            limits: limits,
          );
        case FileSystemEntityType.link:
          // 跟随符号链接：检查链接目标类型
          try {
            final target = await Link(entry.path).target();
            final targetType = await FileSystemEntity.type(
              target,
              followLinks: true,
            );
            if (targetType == FileSystemEntityType.file) {
              // P0-6 兜底：链接目标超大则跳过
              final linkSize = await File(target).length();
              if (linkSize > limits.maxPackSingleFile) {
                debugPrint('[FolderArchive] 跳过超大链接文件 "${entry.path}"');
                continue;
              }
              final fileBytes = await File(target).readAsBytes();
              archive.add(ArchiveFile('$parentPath/$name', fileBytes.length, fileBytes));
            } else if (targetType == FileSystemEntityType.directory) {
              await addDirectoryToArchive(
                archive,
                Directory(target),
                '$parentPath/$name',
                limits: limits,
              );
            }
          } catch (e) {
            debugPrint('[FolderArchive] 无法跟随链接 "${entry.path}": $e');
          }
        default:
          break;
      }
    }
  }

  /// 检测所有文件条目是否共享一个顶层目录前缀。
  /// 发送端把整个文件夹打包时，所有路径都以文件夹名开头，
  /// 剥离前缀避免 targetDir/folderName/file 双层嵌套。
  /// 无共同前缀（含顶层散文件）返回 null。
  static String? commonTopPrefix(Iterable<String> fileNames) {
    String? prefix;
    for (final name in fileNames) {
      final parts = name.split('/');
      if (parts.length <= 1) return null;
      final first = parts[0];
      if (prefix == null) {
        prefix = first;
      } else if (prefix != first) {
        return null;
      }
    }
    return (prefix != null && prefix.isNotEmpty) ? prefix : null;
  }

  /// zip 条目安全路径（P0-2/D4 穿越清洗，纯函数）：
  /// 去 `\` 归一化 → 剥离开头 `/`、`../` → 解析中间 `/./` 与 `/../` →
  /// 剥离顶层共同前缀。清洗后为空返回空串（调用方跳过）。
  static String safeZipEntryPath(String raw, {String? commonPrefix}) {
    var safePath = raw.replaceAll('\\', '/');

    // 去除开头的 / 或 ../
    while (safePath.startsWith('/') || safePath.startsWith('../')) {
      if (safePath.startsWith('/')) {
        safePath = safePath.substring(1);
      } else {
        safePath = safePath.substring(3);
      }
    }

    // 规范化路径：解析中间的 /./ 和 /../ 防止路径穿越到目标目录外
    final parts = safePath.split('/');
    final cleanParts = <String>[];
    for (final part in parts) {
      if (part == '..') {
        if (cleanParts.isNotEmpty) cleanParts.removeLast();
      } else if (part != '.' && part.isNotEmpty) {
        cleanParts.add(part);
      }
    }
    safePath = cleanParts.join('/');
    if (safePath.isEmpty) return '';

    // 剥离顶层共同前缀，避免 targetDir/folderName/... 双层嵌套
    if (commonPrefix != null && safePath.startsWith('$commonPrefix/')) {
      safePath = safePath.substring(commonPrefix.length + 1);
    }
    return safePath;
  }

  // E1：zip条目content断言收敛（as留Service层）。
  static List<int>? zipEntryBytes(Object? content) =>
      content is List<int> ? content : null;
}
