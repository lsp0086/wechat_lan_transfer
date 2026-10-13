// E1：文件位置命令纯函数。从 ChatPage._openFileLocation 抽出，可单测。
// 返回系统文件管理器命令；移动端返回 null 走分享面板；Process 启动留宿主。

import 'dart:io';

/// 文件位置打开命令；null 表示走移动端分享。
({String exe, List<String> args})? buildOpenLocationCommand({
  required bool isWindows,
  required bool isMacOS,
  required bool isLinux,
  required bool isDirectory,
  required String filePath,
  required String dirPath,
}) {
  if (isWindows) {
    if (isDirectory) return (exe: 'explorer', args: [filePath]);
    return (exe: 'explorer', args: ['/select,', filePath]);
  }
  if (isMacOS) {
    if (isDirectory) return (exe: 'open', args: [filePath]);
    return (exe: 'open', args: ['-R', filePath]);
  }
  if (isLinux) {
    if (isDirectory) return (exe: 'xdg-open', args: [filePath]);
    return (exe: 'xdg-open', args: [dirPath]);
  }
  return null;
}

/// 分享主题文件名（空路径回退）。
String shareSubjectOf(String filePath, {required String basename}) =>
    basename.isEmpty ? filePath : basename;

// E1：zip 清理文件回退（finally 删残留，zipFile 为空回退按路径重建）。
File resolveZipFile(File? f, String fallbackPath) => f ?? File(fallbackPath);
