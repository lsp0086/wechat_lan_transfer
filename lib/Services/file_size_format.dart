// E1/U5：从 FileTransferService/AudioService 抽出的纯函数，无状态、可单测。
// 对标 LocalSend/主流文件管理器：十进制 SI 单位（1000 进制），与二进制 KiB 区分。

/// 十进制人类可读文件大小：B / KB / MB / GB（1000 进制）。
String formatFileSize(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes < 1000) return '$bytes B';
  if (bytes < 1000 * 1000) return '${(bytes / 1000).toStringAsFixed(1)} KB';
  if (bytes < 1000 * 1000 * 1000) {
    return '${(bytes / (1000 * 1000)).toStringAsFixed(2)} MB';
  }
  return '${(bytes / (1000 * 1000 * 1000)).toStringAsFixed(2)} GB';
}

/// 接收对话框尺寸后缀：>0 显示“(大小)”，否则空串（三处重复收敛）。
String formatSizeSuffix(int fileSize, String Function(int) format) =>
    fileSize > 0 ? '(${format(fileSize)})' : '';

/// 到达/pending 文件大小文案：>0 显示格式化，否则 null（三处重复收敛）。
String? formatSizeTextOrNull(int fileSize, String Function(int) format) =>
    fileSize > 0 ? format(fileSize) : null;
