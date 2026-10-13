// E1：接收请求对话框纯文案。从 ChatListPage._showReceiveDialog 抽出，可单测。
// 标题/文件名行/大小行/批量提示均纯函数；弹窗与后续 accept/reject 编排留宿主。

/// 接收请求对话框标题：批量（count>1）带总数，否则单文件标题。
String receiveDialogTitle(String label, String? sessionId, int? fileCount) {
  final isBatch = sessionId != null && (fileCount ?? 0) > 1;
  return isBatch ? '$label 批量传输请求（共 $fileCount 个）' : '$label 传输请求';
}

/// 接收请求对话框文件名行：批量显示 `首文件名 等 N 个文件`。
String receiveDialogFileLine(String fileName, String? sessionId, int? fileCount) {
  final isBatch = sessionId != null && (fileCount ?? 0) > 1;
  return isBatch ? '$fileName 等 $fileCount 个文件' : fileName;
}

/// 是否批量接收（一次同意管整批）。
bool isBatchReceive(String? sessionId, int? fileCount) =>
    sessionId != null && (fileCount ?? 0) > 1;
