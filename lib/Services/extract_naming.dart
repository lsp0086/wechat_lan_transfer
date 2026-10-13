// E1：接收 zip 解压目标命名。从 ChatPage._extractReceivedZip 抽出的纯函数，可单测。
// 去 .zip 后缀（否则加 _extracted）+ 已存在目录加 `name (1/2/…)`（U5 对齐主流命名）。

/// 按 zip 文件名算解压文件夹基名（去 .zip 后缀，否则加 _extracted）。
String extractFolderBase(String zipFileName) {
  if (zipFileName.toLowerCase().endsWith('.zip')) {
    return zipFileName.substring(0, zipFileName.length - 4);
  }
  return '${zipFileName}_extracted';
}

/// 在已存在名集合中找可用名：基名空闲直接用，否则 `基名 (1/2/…)`。
String uniqueFolderName({
  required String base,
  required Set<String> existing,
}) {
  if (!existing.contains(base)) return base;
  var counter = 1;
  while (existing.contains('$base ($counter)')) {
    counter++;
  }
  return '$base ($counter)';
}
