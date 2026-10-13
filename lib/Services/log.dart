// 新库 logging：统一日志入口。从散落 debugPrint 收敛到 Logger 层级。
// v2 重构增强：拦截全局 debugPrint，全量镜像写入应用文档目录
// （macOS 沙盒容器 …/Data/Documents/wlt_runtime.log），解决 release 包
// 无文件日志可用、传输问题无法定位的问题。文件写入失败静默降级为仅打屏。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

bool _loggingInited = false;
IOSink? _logSink;
bool _fileLogBroken = false;
int _bytesWritten = 0;

/// 运行日志文件名（应用文档目录下）。
const String kRuntimeLogFileName = 'wlt_runtime.log';

/// 单文件日志上限（超过即停止追加，防无限增长）。
const int _kMaxLogFileBytes = 2 * 1024 * 1024;

/// main() 启动时调用一次；测试环境重复调用安全。
void initLogging({Level level = Level.ALL}) {
  if (_loggingInited) return;
  _loggingInited = true;
  Logger.root.level = level;
  Logger.root.onRecord.listen((rec) {
    debugPrint('[${rec.loggerName}] ${rec.level.name}: ${rec.message}');
  });
  unawaited(_startFileLog());
}

/// 启动文件日志：清空旧文件 → 打开追加句柄 → 拦截全局 debugPrint 镜像写入
/// → 周期 flush。任何一步失败都只降级为打屏（不影响主流程）。
Future<void> _startFileLog() async {
  try {
    final docDir = await getApplicationDocumentsDirectory();
    final file = File('${docDir.path}/$kRuntimeLogFileName');
    // 每次启动重建日志（避免跨次启动混淆；本次运行的现场完整记录）
    if (await file.exists()) await file.delete();
    _logSink = file.openWrite(mode: FileMode.append);
    Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_logSink?.flush().catchError((Object _) {}));
    });
    // 拦截全局 debugPrint：先保持原打屏行为，再镜像落盘。
    // 注意：_appendFile 内部绝不能再走 debugPrint，防递归。
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      original(message, wrapWidth: wrapWidth);
      _appendFile(message ?? '');
    };
    debugPrint('[Log] 文件日志已启动: ${file.path}');
  } catch (e) {
    // 拿不到文档目录（测试环境/平台差异）：仅打屏
    _fileLogBroken = true;
    // 此时 debugPrint 尚未被本函数拦截，直接打屏不会递归
    debugPrint('[Log] 文件日志启动失败（仅打屏）: $e');
  }
}

/// 追加一行到日志文件（带时间戳；失败即永久降级，不再尝试）。
void _appendFile(String message) {
  final sink = _logSink;
  if (sink == null || _fileLogBroken) return;
  try {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    final bytes = utf8.encode('[$ts] $message\n');
    if (_bytesWritten + bytes.length > _kMaxLogFileBytes) {
      _fileLogBroken = true; // 超上限停止追加
      return;
    }
    _bytesWritten += bytes.length;
    sink.add(bytes);
  } catch (_) {
    _fileLogBroken = true;
  }
}

/// 各模块按名取 Logger（Discovery/FolderArchive/MessageCache …）。
Logger moduleLog(String name) => Logger(name);
