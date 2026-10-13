import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// E4：极简文件日志——内存保留最近 1000 条，追加写 documents/logs/app.log。
/// 关键路径保留 debugPrint 兼容（同步打屏，文件写为 fire-and-forget）。
/// E4：2MB 轮转，保留 app.log + app.log.1/2 共 3 份，超限删最旧。
class AppLogger {
  AppLogger._();
  static final AppLogger instance = AppLogger._();

  static const int maxMemoryLines = 1000;
  static const int maxFileBytes = 2 * 1024 * 1024;
  static const int maxBackupFiles = 2;
  final List<String> _memory = [];

  List<String> get memoryLogs => List.unmodifiable(_memory);

  void log(String message) {
    final line = '[${DateTime.now().toIso8601String()}] $message';
    _memory.add(line);
    if (_memory.length > maxMemoryLines) {
      _memory.removeRange(0, _memory.length - maxMemoryLines);
    }
    debugPrint(message);
    _appendToFile(line);
  }

  Future<void> _appendToFile(String line) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/logs');
      if (!await dir.exists()) await dir.create(recursive: true);
      final main = File('${dir.path}/app.log');
      if (await main.exists() &&
          (await main.length()) + line.length + 1 > maxFileBytes) {
        await _rotate(dir.path);
      }
      await main.writeAsString(
        '$line\n',
        mode: FileMode.append,
        flush: false,
      );
    } catch (e) {
      debugPrint('[AppLogger] 写日志文件失败: $e');
    }
  }

  /// E4：app.log -> app.log.1 -> app.log.2，超限删最旧。
  Future<void> _rotate(String dirPath) async {
    try {
      final oldest = File('$dirPath/app.log.$maxBackupFiles');
      if (await oldest.exists()) await oldest.delete();
      for (var i = maxBackupFiles - 1; i >= 1; i--) {
        final src = File('$dirPath/app.log.$i');
        if (await src.exists()) {
          await src.rename('$dirPath/app.log.${i + 1}');
        }
      }
      final main = File('$dirPath/app.log');
      if (await main.exists()) await main.rename('$dirPath/app.log.1');
    } catch (e) {
      debugPrint('[AppLogger] 日志轮转失败: $e');
    }
  }

  /// 导出日志文件路径（不存在返回 null），供分享/排查用。
  Future<String?> exportPath() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final f = File('${docs.path}/logs/app.log');
      if (await f.exists()) return f.path;
      return null;
    } catch (_) {
      return null;
    }
  }
}
