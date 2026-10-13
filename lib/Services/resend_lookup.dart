// E1：迟到 accept 重发查找。从 ChatPage._onFileAcceptReceived 抽出的纯函数，可单测。
// 在“我发送的、失败的、有本地路径的文件/图片/语音”中找重发目标：
// transferId 精确匹配优先，旧端无 transferId 时兼容 `fileName.zip` 回退。

import 'package:wechat_lan_transfer/Model/chat_model.dart';
import 'package:wechat_lan_transfer/Services/session_tracker.dart'
    show pendingTransferMatches;
import 'transfer_state_map.dart' show isResumableMsgState;

/// 接收重传旧消息下标（_onFileReceived  indexWhere 收敛，纯函数可单测）。
int findInboundResendIndex({
  required List<ChatMessage> chatData,
  required String? transferId,
  required String fileName,
}) {
  for (var i = chatData.length - 1; i >= 0; i--) {
    final m = chatData[i];
    if (m.isMe || !isResumableMsgState(m.transferState)) continue;
    if (pendingTransferMatches(
      messageTransferId: m.transferId,
      messageFileName: m.fileName,
      transferId: transferId,
      fileName: fileName,
    )) {
      return i;
    }
  }
  return -1;
}

/// 重发目标下标（无命中返回 -1，调用方跳过）。
int findResendTargetIndex({
  required List<ChatMessage> chatData,
  required String? transferId,
  required String fileName,
}) {
  for (var i = chatData.length - 1; i >= 0; i--) {
    final m = chatData[i];
    if (!m.isMe ||
        (m.type != MessageType.file &&
            m.type != MessageType.image &&
            m.type != MessageType.audio) ||
        m.transferState != TransferState.failed ||
        m.filePath == null) {
      continue;
    }
    if (pendingTransferMatches(
      messageTransferId: m.transferId,
      messageFileName: m.fileName,
      transferId: transferId,
      fileName: fileName,
    )) {
      return i;
    }
    if ((transferId == null || transferId.isEmpty) &&
        '${m.fileName}.zip' == fileName) {
      return i;
    }
  }
  return -1;
}
