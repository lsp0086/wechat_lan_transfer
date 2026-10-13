// E1：缓存恢复决策。从 ChatPage._initChat 恢复分支抽出的可单测纯逻辑。
// 活动态（transferring/pending/sending）中断修复 + 追认完成判定 +
// 已完成文件夹追认解压门控；IO（exists 检查/解压执行）留宿主。

import 'package:wechat_lan_transfer/Model/chat_model.dart';
import 'transfer_state_map.dart';

/// 恢复动作：追认完成 / 标记中断 / 追认解压检查 / 保持原样。
enum RecoveryAction { recoverCompleted, markInterrupted, checkPostExtract, keep }

/// 单条消息恢复决策（纯函数，不做 IO）。
RecoveryAction decideRecoveryAction({
  required TransferState state,
  required bool isMe,
  required MessageType type,
  required bool hasPath,
  required bool isFolder,
}) {
  if (isActiveMsgState(state)) {
    final receivable = !isMe && type != MessageType.text && hasPath;
    if (receivable) return RecoveryAction.recoverCompleted;
    return RecoveryAction.markInterrupted;
  }
  if (needsPostCompleteExtract(
    state: state,
    isMe: isMe,
    isFolder: isFolder,
    filePath: hasPath ? '' : null,
  )) {
    return RecoveryAction.checkPostExtract;
  }
  return RecoveryAction.keep;
}

/// 是否需要追认完成（收到非文字 + 有路径 + 磁盘存在）。
bool shouldRecoverCompleted({
  required bool fileExists,
  required bool dirExists,
}) =>
    fileExists || dirExists;

/// 启动缓冲事件分流：transferring 新任务（未建气泡）先走接收创建再走进度。
bool shouldCreateBeforeProgress({
  required bool isTransferring,
  required bool hasBubble,
}) =>
    isTransferring && !hasBubble;

// E1：恢复修复动作判定收敛（追认完成/标记中断两支）。
bool isRecoveryFixAction(RecoveryAction a) =>
    a == RecoveryAction.recoverCompleted || a == RecoveryAction.markInterrupted;

// E1：==收敛（追认完成动作判定）。
bool isRecoverCompletedAction(RecoveryAction a) =>
    a == RecoveryAction.recoverCompleted;

// E1：==收敛（追认解压检查动作判定）。
bool isCheckPostExtractAction(RecoveryAction a) =>
    a == RecoveryAction.checkPostExtract;

// E1：==收敛（transferring状态名字符串判定）。
bool isTransferringStatus(String n) => n == 'transferring';
