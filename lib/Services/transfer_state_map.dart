// E1：传输状态映射。从 ChatPage._transferTaskToMsgState 抽出的纯函数，可单测。
// （v2 重构：TransferStatus→TransferState 映射函数已删，气泡状态直接由
//   LsServer/LsClient 回调写入 ChatMessage.transferState。）

import 'package:wechat_lan_transfer/Model/chat_model.dart';

/// 是否为终态（completed/failed），终态才写缓存。
bool isTerminalMsgState(TransferState state) =>
    state == TransferState.completed || state == TransferState.failed;

/// 终态保护：已 completed/failed 的消息不再回退。
bool shouldGuardTerminal(TransferState current) =>
    current == TransferState.completed || current == TransferState.failed;

/// 是否为活动态（transferring/pending/sending），离页确认/中断修复用。
bool isActiveMsgState(TransferState state) =>
    state == TransferState.transferring ||
    state == TransferState.pending ||
    state == TransferState.sending;

/// file_cancel 是否只处理活动态（transferring/pending）。
bool isCancelActiveState(TransferState state) =>
    state == TransferState.transferring || state == TransferState.pending;

/// 是否为可续传态（pending/failed），重传旧消息查找用。
bool isResumableMsgState(TransferState state) =>
    state == TransferState.pending || state == TransferState.failed;

/// 气泡视图状态快照（E1：聊天气泡三处重复 bool 收敛，纯函数可单测）。
/// transferring→进度条/取消按钮；failed→重发入口；sending→长按禁用；
/// completed→文件动作/图片预览；pending→接收/拒绝按钮。
class MsgBubbleFlags {
  final bool isTransferring;
  final bool isFailed;
  final bool isSending;
  final bool isCompleted;
  final bool isPending;
  const MsgBubbleFlags({
    required this.isTransferring,
    required this.isFailed,
    required this.isSending,
    required this.isCompleted,
    required this.isPending,
  });
}

/// 从消息状态一次算出气泡全部 bool，避免三处重复比较。
MsgBubbleFlags bubbleFlagsOf(TransferState state) => MsgBubbleFlags(
      isTransferring: state == TransferState.transferring,
      isFailed: state == TransferState.failed,
      isSending: state == TransferState.sending,
      isCompleted: state == TransferState.completed,
      isPending: state == TransferState.pending,
    );

/// 文件动作是否可点（已完成 + 有路径）。
bool canShowFileActions(TransferState state, String? filePath) =>
    state == TransferState.completed && filePath != null;

/// 文本复制是否可点（非文件 + 内容非空）。
bool canShowCopyAction({required bool isFile, required String content}) =>
    !isFile && content.isNotEmpty;

/// 是否为接收完成待解压（收到的已完成文件夹 + 有路径）。
bool needsPostCompleteExtract({
  required TransferState state,
  required bool isMe,
  required bool isFolder,
  required String? filePath,
}) =>
    state == TransferState.completed &&
    !isMe &&
    isFolder &&
    filePath != null;

/// file_reject 是否只处理我发的传输中文件/图片/语音。
bool isRejectTarget({
  required bool isMe,
  required TransferState state,
}) =>
    isMe && state == TransferState.transferring;

/// file_reject 文件名匹配（含 zip 回退：xxx.zip 命中 xxx）。
bool rejectFileNameMatches({
  required String? messageFileName,
  required String fileName,
}) =>
    messageFileName == fileName || '$messageFileName.zip' == fileName;

/// 接收完成解压门控：已完成 + 非发送 + 文件夹（三条件 && 收敛）。
bool shouldExtractReceivedZip({
  required TransferState state,
  required bool isSender,
  required bool isFolder,
}) =>
    state == TransferState.completed && !isSender && isFolder;

/// 全局进度成功映射：成功 completed/1.0，否则 failed/0.0（双三元收敛）。
TransferState mapGlobalProgressState({required bool isSuccess}) =>
    isSuccess ? TransferState.completed : TransferState.failed;

/// 全局进度值映射：成功 1.0，否则 0.0。
double mapGlobalProgressValue({required bool isSuccess}) =>
    isSuccess ? 1.0 : 0.0;

/// file_reject 倒序首个目标下标（发送侧 file/图片/语音 + 传输中 + 文件名命中）。
int findRejectTargetIndex({
  required List<ChatMessage> chatData,
  required String fileName,
}) {
  for (var i = chatData.length - 1; i >= 0; i--) {
    final m = chatData[i];
    if (!isRejectTarget(isMe: m.isMe, state: m.transferState)) continue;
    if (m.type != MessageType.file &&
        m.type != MessageType.image &&
        m.type != MessageType.audio) {
      continue;
    }
    if (rejectFileNameMatches(messageFileName: m.fileName, fileName: fileName)) {
      return i;
    }
  }
  return -1;
}

// E1：接收进度门控收敛（非发送侧才处理全局进度）。
bool isReceivableProgress({required bool isSender}) => !isSender;

// E1：拒绝候选判定收敛（非本人 + pending 才可拒，调用点取反早退）。
bool isRejectCandidate({required bool isMe, required String stateName}) =>
    !isMe && stateName == 'pending';
