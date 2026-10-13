// E1：发送等待/异常文案。从 ChatPage._sendFileFromPath 残留抽出，可单测。

import 'transfer_limits.dart';

/// 等待对方同意文案。
String buildSendWaitingContent({
  required String errLabel,
  required String displayName,
}) =>
    '$errLabel 等待对方同意: $displayName';

/// PIN 必填拒绝文案。
String buildPinRequiredFailure({
  required String errLabel,
  required String displayName,
}) =>
    '$errLabel 对方已拒绝: $displayName（需 PIN）';

/// 发送异常拼接文案（截断后的堆栈拼一行）。
String buildSendExceptionContent({
  required String errLabel,
  required String displayName,
  required String truncatedError,
}) =>
    '$errLabel 发送失败: $displayName\n$truncatedError';

/// 语音握手失败文案（与 audioHandshakeContent 同义，语音发送侧用）。
String audioHandshakeFailedContent({required bool rejected}) => rejected
    ? '语音消息（对方已拒绝）'
    : '语音消息（等待超时，对方稍后同意可继续接收）';

/// 录音过短门控（默认 500ms 以下丢弃）。
/// E1：抽至 transfer_limits.kMinRecordMs/kRecordCancelFactor。
bool isTooShortRecord({required int? durationMs, int minMs = kMinRecordMs}) =>
    durationMs == null || durationMs < minMs;

/// 录音取消区判定（上滑超 0.35 屏高即取消）。
bool isInRecordCancelZone({
  required double globalY,
  required double screenHeight,
  double factor = kRecordCancelFactor,
}) =>
    globalY < screenHeight * factor;

/// pending 标签：文件夹 📁，文件 📥。
String pendingLabel({required bool isFolder}) => isFolder ? '📁' : '📥';

/// pending 内容：标签 + 等待接收 + 文件名 + 批量后缀。
String buildPendingContent({
  required String label,
  required String fileName,
  required String batchSuffix,
}) =>
    '$label 等待接收: $fileName$batchSuffix';

/// 选择器/发送失败文案（E1：_openFilePicker/_openFolderPicker/_sendFolderByPath）。
String filePickFailedText(Object e) => '文件选择失败: $e';
String folderPickFailedText(Object e) => '文件夹发送失败: $e';
String folderMissingText() => '文件夹不存在';
String folderEmptyText() => '所选文件夹为空';
String folderPackFailedText() => '文件夹打包失败';
String folderAccessDeniedText() => '需要"所有文件访问"权限才能发送文件夹';

/// 解压提示文案（E1：_extractReceivedZip）。
String extractTooLargeText(String zipFileName) =>
    '文件夹过大，无法自动解压（$zipFileName）';
String extractAbortedText(String zipFileName) =>
    '文件夹过大，已停止解压（$zipFileName）';

/// 拉黑/离线门控 toast（E1：_checkTargetOnline/_onMsgAckReceived 共用）。
String blockedByPeerText() => '对方已拉黑，无法发送';
String peerOfflineText() => '对方未在线，无法发送';
String blockedAndRejectedText() => '对方已拉黑，已拒收消息';

/// 录音/分享/位置提示（E1：录音与文件动作共用）。
String recordTooShortText() => '录音时间太短';
String copyDoneText() => '已复制';
String openLocationFailedText() => '无法打开文件位置';
String shareFailedText() => '无法分享该文件';

/// PIN 对话框文案（E1：_promptForPin）。
String pinDialogTitle() => '对方要求输入 PIN';
String pinDialogHint() => '4~8 位数字';
String pinWrongHint() => 'PIN 错误，请重新输入对方的接收 PIN';
String pinRequiredHint() => '对方已启用接收 PIN，请输入后重试';

/// PIN 提示分支：pinWrong 走错误提示，否则走必填提示（三处三元收敛）。
String resolvePinHint(String? reason) =>
    reason == 'pinWrong' ? pinWrongHint() : pinRequiredHint();
