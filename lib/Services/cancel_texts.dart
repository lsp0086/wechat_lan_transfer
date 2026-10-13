// E1：取消文案。从 ChatPage._cancelTransfer/_onFileCancelReceived 抽出的纯函数，可单测。
// 本地取消与对端取消共用：语音恒为“语音消息”，文件按我是发送/接收方区分。

/// 本地取消文案（点击取消按钮后）。
String localCancelContent({
  required bool isAudio,
  required bool isMe,
  required String fileName,
}) {
  if (isAudio) return '语音消息';
  return isMe ? '📤 已取消发送: $fileName' : '📥 已取消接收: $fileName';
}

/// 对端取消文案（收到 file_cancel 后）。
String peerCancelContent({
  required bool isAudio,
  required bool isMe,
  required String fileName,
}) {
  if (isAudio) return '语音消息';
  return isMe ? '📤 对方已取消: $fileName' : '📥 对方已取消: $fileName';
}
