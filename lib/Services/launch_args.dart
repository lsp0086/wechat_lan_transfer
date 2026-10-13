// U2：桌面启动参数（Windows 右键"发送到"/"打开方式"、Linux .desktop Exec %F、
// macOS open --args 透传的文件路径）。
// Windows runner 已透传命令行参数到 set_dart_entrypoint_arguments；
// Linux/macOS 同理。收集第一个非开关、存在的文件/目录路径。
// 参数约定：`--send <path>...` 或裸路径（兼容"打开方式"的直接透传）。

import 'dart:io';

class LaunchArgs {
  LaunchArgs._();

  /// 从启动参数收集待发送路径（文件/目录需存在）。
  /// args 为空（移动端/IDE 启动）时用 Platform.executableArguments。
  static List<String> pendingPaths([List<String>? args]) {
    final raw = args ?? [];
    // 过滤 Dart/Flutter 自身开关（--dart-entrypoint-args 等透传噪声）。
    final cleaned = raw
        .where((a) => a.isNotEmpty && a != '--' && !a.startsWith('--dart-'))
        .toList();
    final out = <String>[];
    var filesOnly = false;
    for (var i = 0; i < cleaned.length; i++) {
      final a = cleaned[i];
      if (a == '--send') {
        filesOnly = true;
        continue;
      }
      if (!filesOnly && a.startsWith('--')) continue;
      if (a.startsWith('--')) continue;
      var p = a;
      if (p.startsWith('file://')) {
        try {
          p = Uri.parse(p).toFilePath();
        } catch (_) {}
      }
      p = p.trim().replaceAll('"', '');
      if (p.isEmpty) continue;
      try {
        final type = FileSystemEntity.typeSync(p, followLinks: false);
        if (type == FileSystemEntityType.file ||
            type == FileSystemEntityType.directory) {
          out.add(p);
        }
      } catch (_) {}
    }
    return out;
  }
}
