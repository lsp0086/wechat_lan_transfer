// E1：file_notify pending 去重。从 ChatPage._onFileNotifyReceived 抽出的纯函数，可单测。
// 仅“我收到的、pending/failed 的文件”参与去重；transferId 精确匹配优先。

import 'package:wechat_lan_transfer/Model/chat_model.dart';
import 'package:wechat_lan_transfer/Services/session_tracker.dart'
    show pendingTransferMatches;

/// 是否已存在同 transferId/文件名的 pending（重复 notify 跳过）。
bool hasPendingDuplicate({
  required List<ChatMessage> chatData,
  required String? transferId,
  required String fileName,
}) {
  return chatData.any((m) {
    if (m.isMe) return false;
    if (m.transferState != TransferState.failed &&
        m.transferState != TransferState.pending) {
      return false;
    }
    return pendingTransferMatches(
      messageTransferId: m.transferId,
      messageFileName: m.fileName,
      transferId: transferId,
      fileName: fileName,
    );
  });
}
