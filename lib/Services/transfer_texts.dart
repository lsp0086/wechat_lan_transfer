// E1：传输气泡文案。从 ChatPage 抽出的纯函数（可单测，无 UI 依赖）。
// 发送/接收共用：文件夹去 .zip 后缀展示、进度百分比、速度/ETA 尾巴。
// （v2 重构：FileTransferTask 版 sendContent/receiveContent 已删，
//   v2 气泡文案走 globalProgressContent 等，见 chat_list _onLsFileResult。）

import 'package:wechat_lan_transfer/Model/chat_model.dart';

class TransferTexts {
  TransferTexts._();

  /// 发送握手失败文案（E1：从 ChatPage._sendFileFromPath 抽出，可单测）。
  /// [rejected] 对方明确拒绝 vs 等待超时；[reason] file_reject 结构化原因。
  static String sendFailure({
    required String errLabel,
    required String displayName,
    required bool rejected,
    String? reason,
  }) {
    if (!rejected) return '$errLabel 等待超时: $displayName（对方稍后同意可继续接收）';
    if (reason == 'pinRequired' || reason == 'pinWrong') {
      return '$errLabel 对方已拒绝: $displayName（PIN 错误）';
    }
    if (reason == 'noSpace') return '$errLabel 对方空间不足: $displayName';
    return '$errLabel 对方已拒绝: $displayName';
  }

  /// 异常截断（E1：发送异常气泡超长堆栈截断 100 字符）。
  static String truncateError(Object e, {int maxChars = 100}) {
    final s = e.toString();
    return s.length > maxChars ? s.substring(0, maxChars) : s;
  }

  /// 音频补元门控（E1：_updateAudioMeta 播放器时长/波形回退用）。
  static bool needsAudioMetaFill({
    required int durationMs,
    required String? waveformData,
  }) =>
      durationMs <= 0 ||
      waveformData == null ||
      waveformData.isEmpty;

  /// 音频补元波形回退（E1：已有波形沿用，缺失才回退空采样编码）。
  static String? resolveAudioWaveform({
    required String? existing,
    required String fallback,
  }) =>
      (existing != null && existing.isNotEmpty) ? existing : fallback;

  /// 传输完成补元触发（E1：图片缩略图/音频时长波形两路共用）。
  static bool shouldFillMetaAfterComplete({
    required TransferState state,
    required MessageType type,
    required MessageType want,
    int durationMs = 1,
    String? waveformData = 'x',
  }) {
    if (state != TransferState.completed || type != want) return false;
    if (want != MessageType.audio) return true;
    return needsAudioMetaFill(
      durationMs: durationMs,
      waveformData: waveformData,
    );
  }

  /// 缓存恢复中断文案（E1：_initChat 历史遗留 transferring/pending/sending 标记失败用）。
  /// 语音恒为“语音消息”；文字按发送/接收区分；文件按发送/接收区分。
  static String interruptedContent({
    required bool isAudio,
    required bool isText,
    required bool isMe,
    required String content,
    required String fileName,
  }) {
    if (isAudio) return '语音消息';
    if (isText) return isMe ? '⚠️ 发送中断: $content' : '📥 接收中断: $content';
    return isMe ? '📤 发送中断: $fileName' : '📥 接收中断: $fileName';
  }

  /// 追认完成文案（E1：关闭期间实际落盘的文件追认为 completed 用）。
  static String recoveredContent({
    required bool isFolder,
    required String fileName,
  }) =>
      '${isFolder ? "📁" : "📥"} 接收完成: $fileName';

  /// 全局进度结果文案（E1：chat_list 全局进度监听更新缓存用）。
  static String globalProgressContent({
    required bool isAudio,
    required bool isSuccess,
    required bool isFolder,
    required String fileName,
  }) {
    if (isAudio) return '语音消息';
    if (isSuccess) return '${isFolder ? "📁" : "📥"} 接收完成: $fileName';
    return '📥 接收失败: $fileName';
  }

  /// 对方拒绝文案（E1：_onFileRejectReceived 落 failed 气泡用）。
  static String rejectContent({
    required bool isAudio,
    required String fileName,
  }) =>
      isAudio ? '语音消息' : '📤 对方拒绝接收: $fileName';

  /// 本人拒绝文案（E1：_onUserRejectPending/_updatePendingToRejected 用）。
  static String selfRejectContent(String fileName) => '📥 已拒绝接收: $fileName';

  /// 等待传输文案（E1：_onUserAcceptPending 手动同意后用）。
  static String waitingContent(String fileName) => '📥 等待传输: $fileName';

  /// 等待对方重新发送文案（E1：接收端失败点击继续接收用）。
  static String waitPeerResendContent(String fileName) =>
      '📥 等待对方重新发送: $fileName';

  /// 文件已删除文案（E1：重发前文件丢失用）。
  static String fileDeletedContent({
    required String errLabel,
    required String displayName,
  }) =>
      '$errLabel 文件已删除: $displayName';

  /// 重新发送中文案（E1：迟到 accept 找到目标后用）。
  static String resendingContent(String fileName) => '📤 重新发送中: $fileName';

  /// 文字发送失败文案（E1：ACK 超时/拉黑统一用，点击重发）。
  static String textSendFailedContent(String text) =>
      '⚠️ 发送失败: $text\n（点击重发）';

  /// 语音重发缺文件文案（E1：_directResendFile/_retrySendAudio 用）。
  static String audioMissingContent({
    required bool isAudio,
    required bool isFolder,
    required String displayName,
  }) =>
      isAudio
          ? '语音消息（文件已删除）'
          : '${isFolder ? "📁" : "📤"} 文件已删除: $displayName';

  /// 语音重发失败文案（E1：_directResendFile/_retrySendAudio 用）。
  static String audioSendFailedContent({
    required bool isAudio,
    required bool isFolder,
    required String displayName,
  }) =>
      isAudio
          ? '语音消息'
          : '${isFolder ? "📁" : "📤"} 发送失败: $displayName';

  /// 语音握手结果文案（E1：_retrySendAudio 迟到 accept 三态用）。
  static String audioHandshakeContent({required bool rejected}) => rejected
      ? '语音消息（对方已拒绝）'
      : '语音消息（等待超时，对方稍后同意可继续接收）';

  /// 语音等待同意文案（E1：_retrySendAudio 重试 pending 用）。
  static String audioWaitingContent() => '语音消息（等待对方同意）';

  /// E1：失败变异纯函数（copyWith failed 收敛，宿主只留 setState 赋值）。
  /// 文字失败：原文包失败文案 + failed。
  static ChatMessage markTextFailed(ChatMessage old, String text) =>
      old.copyWith(
        content: textSendFailedContent(text),
        transferState: TransferState.failed,
      );

  /// 通用失败：沿用旧 content，仅标 failed。
  static ChatMessage markFailedKeepContent(ChatMessage old) =>
      old.copyWith(transferState: TransferState.failed);

  /// E1：失败变异纯函数（带新 content，宿主文案计算保留，仅 copyWith 收敛）。
  /// 中断（_initChat 缓存恢复用，content 已由 interruptedContent 算好）。
  static ChatMessage markInterrupted(ChatMessage old, String content) =>
      old.copyWith(content: content, transferState: TransferState.failed);

  /// 对方拒绝（_onFileRejectReceived 用）。
  static ChatMessage markReject(ChatMessage old, String content) =>
      old.copyWith(content: content, transferState: TransferState.failed);

  /// 本人拒绝（_onUserRejectPending/chat_list pending 拒绝用）。
  static ChatMessage markSelfReject(ChatMessage old, String content) =>
      old.copyWith(content: content, transferState: TransferState.failed);

  /// 本地取消（_cancelTransfer 用，content 已由 cancel_texts 算好）。
  static ChatMessage markCancelLocal(ChatMessage old, String content) =>
      old.copyWith(content: content, transferState: TransferState.failed);

  /// 对端取消（_onFileCancelReceived/chat_list 全局取消用）。
  static ChatMessage markPeerCancel(ChatMessage old, String content) =>
      old.copyWith(content: content, transferState: TransferState.failed);

  /// 文件已删除（重发前文件丢失用）。
  static ChatMessage markFileDeleted(ChatMessage old, String content) =>
      old.copyWith(content: content, transferState: TransferState.failed);

  /// 发送握手失败（等待超时/对方拒绝用，content 已由 sendFailure 算好）。
  static ChatMessage markSendFailure(ChatMessage old, String content) =>
      old.copyWith(content: content, transferState: TransferState.failed);

  /// 发送异常（_sendFileFromPath catch 用）。
  static ChatMessage markSendException(ChatMessage old, String content) =>
      old.copyWith(content: content, transferState: TransferState.failed);

  /// 语音缺文件（_directResendFile/_retrySendAudio 用）。
  static ChatMessage markAudioMissing(ChatMessage old, String content) =>
      old.copyWith(content: content, transferState: TransferState.failed);

  /// 语音发送失败（_directResendFile/_retrySendAudio 用）。
  static ChatMessage markAudioSendFailed(ChatMessage old, String content) =>
      old.copyWith(content: content, transferState: TransferState.failed);

  /// 语音握手结果（等待超时/对方拒绝用，含 send_waiting 同义文案）。
  static ChatMessage markAudioHandshake(ChatMessage old, String content) =>
      old.copyWith(content: content, transferState: TransferState.failed);

  /// 语音恒定标签失败（audioLabel 沿用旧语义，仅标 failed）。
  static ChatMessage markAudioLabel(ChatMessage old, String content) =>
      old.copyWith(content: content, transferState: TransferState.failed);

  /// 解压中止（_extractReceivedZip 超限用）。
  static ChatMessage markExtractAborted(ChatMessage old, String content) =>
      old.copyWith(content: content, transferState: TransferState.failed);

  /// 通用带新 content 失败（_failSendFile 等提前返回路径用）。
  static ChatMessage markFailedWithContent(ChatMessage old, String content) =>
      old.copyWith(content: content, transferState: TransferState.failed);

  /// E1：追认完成变异（缓存恢复磁盘已存在用，content 已由 recoveredContent 算好）。
  static ChatMessage markRecovered(ChatMessage old, String content) =>
      old.copyWith(content: content, transferState: TransferState.completed);

  /// E1：重发传输中变异（迟到 accept/重发用，content 已由 resendingContent 算好）。
  static ChatMessage markResending(ChatMessage old, String content) =>
      old.copyWith(
        content: content,
        transferState: TransferState.transferring,
        progress: 0.0,
      );

  /// E1：等待变异（手动同意/等待对方重发用，content 已由 waiting/waitPeerResend 算好）。
  static ChatMessage markWaiting(ChatMessage old, String content) =>
      old.copyWith(content: content, transferState: TransferState.pending);

  /// E1：语音等待变异（重试 pending 用，content 已由 audioWaitingContent 算好）。
  static ChatMessage markAudioWaiting(
    ChatMessage old,
    String content,
    String transferId,
  ) =>
      old.copyWith(
        content: content,
        transferState: TransferState.pending,
        progress: 0.0,
        transferId: transferId,
      );

  /// E1：传输中保持文案（重试首步仅转态用，不改 content）。
  static ChatMessage markTransferringKeepContent(ChatMessage old) =>
      old.copyWith(transferState: TransferState.transferring, progress: 0.0);

  /// E1：完成保持文案（ACK 确认送达用，仅标 completed）。
  static ChatMessage markCompletedKeepContent(ChatMessage old) =>
      old.copyWith(transferState: TransferState.completed);

  /// E1：换握手 ID 变异（PIN 重试换新 transferId 用，仅改 transferId）。
  static ChatMessage markTransferId(ChatMessage old, String? transferId) =>
      old.copyWith(transferId: transferId);

  /// E1：文字重发变异（失败气泡点重发用，content 回原文 + sending）。
  static ChatMessage markTextSending(ChatMessage old, String text) =>
      old.copyWith(content: text, transferState: TransferState.sending);

  /// E1：缩略图回填变异（仅补 thumbnailPath，IO 留宿主）。
  static ChatMessage markThumbnail(ChatMessage old, String? thumbPath) =>
      old.copyWith(thumbnailPath: thumbPath);

  /// E1：音频元数据变异（时长/波形回填用，content 已由 audioLabel 算好）。
  static ChatMessage markAudioMeta(
    ChatMessage old, {
    required int durationMs,
    required String? waveformData,
    required String content,
  }) =>
      old.copyWith(
        durationMs: durationMs,
        waveformData: waveformData,
        content: content,
      );

  /// E1：全局进度变异（chat_list 后台进度用，state/progress 已由 transfer_state_map 算好）。
  static ChatMessage markGlobalProgress(
    ChatMessage old, {
    required String content,
    required TransferState transferState,
    required double progress,
    required String? filePath,
  }) =>
      old.copyWith(
        content: content,
        transferState: transferState,
        progress: progress,
        filePath: filePath,
      );
}
