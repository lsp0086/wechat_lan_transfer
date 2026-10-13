// E1：气泡/命名/门控纯函数。从 ChatPage 残留内联抽出，可单测。

import 'package:wechat_lan_transfer/Model/chat_model.dart';

/// 长按门控：非传输中、非发送中、且（文件或内容非空）才可长按。
bool canLongPressBubble({
  required bool isTransferring,
  required bool isSending,
  required bool isFile,
  required String content,
}) =>
    !isTransferring && !isSending && (isFile || content.isNotEmpty);

/// 取消按钮可见：发送端始终显示；接收端仅非自动接收显示。
bool shouldShowCancel({required bool isMe, required bool autoReceive}) =>
    isMe || !autoReceive;

/// 图片缺失：已完成但两路路径都不存在。
bool isImageMissing({
  required bool isCompleted,
  required bool fileExists,
  required bool originalExists,
}) =>
    isCompleted && !fileExists && !originalExists;

/// 显示图：缩略图 > 原图 > 文件。
String? resolveDisplayImagePath({
  required String? thumb,
  required String? image,
  required String? file,
}) =>
    thumb ?? image ?? file;

/// 原图：原图 > 文件。
String? resolveOriginalImagePath({
  required String? image,
  required String? file,
}) =>
    image ?? file;

/// 进度百分比文案（三处重复收敛）。
String formatProgressPercent(double progress) =>
    '${(progress * 100).toStringAsFixed(0)}%';

/// 头像首字回退（空标题回“机”）。
String avatarLetter(String title, {String fallback = '机'}) =>
    title.isNotEmpty ? title.substring(0, 1) : fallback;

/// 本人头像恒定字。
String selfAvatarLetter() => '我';

/// 气泡主轴对齐：本人右侧，他人左侧（Row 收敛三处重复）。
bool isEndAlign(bool isMe) => isMe;

/// 文件夹展示名：去 .zip 后缀；空名回“未知文件”。
String folderDisplayName({required String? fileName, required bool isFolder}) {
  final name = fileName ?? '未知文件';
  if (!isFolder) return name;
  return name.replaceAll(RegExp(r'\.zip$', caseSensitive: false), '');
}

/// 重发标签：文字“点击重发”，文件“发送失败，点击重试”。
String retryLabel({required bool isText}) =>
    isText ? '点击重发' : '发送失败，点击重试';

/// 空文本判定。
bool isBlankText(String text) => text.trim().isEmpty;

/// 失败气泡逆解析出原文（重发用）。
String extractOriginalTextForResend(String failedContent) => failedContent
    .replaceFirst('⚠️ 发送失败: ', '')
    .replaceFirst(RegExp(r'\n（点击重发）$'), '');

/// 失败态操作可见性：我发的失败显示重试。
bool shouldShowRetryAction({required bool isFailed, required bool isMe}) =>
    isFailed && isMe;

/// 接收端失败请求重发可见：收到的失败 + 非自动接收。
bool shouldShowRequestResend({
  required bool isFailed,
  required bool isMe,
  required bool autoReceive,
}) =>
    isFailed && !isMe && !autoReceive;

/// 对端 pending 判定：收到的 pending 消息。
bool isPeerPending({required bool isMe, required TransferState state}) =>
    !isMe && state == TransferState.pending;

/// 对端 pending 等待圈可见：pending + 自动接收。
bool shouldShowPeerPendingWaiting({
  required bool isPeerPending,
  required bool autoReceive,
}) =>
    isPeerPending && autoReceive;

/// 对端 pending 接收/拒绝按钮可见：pending + 非自动接收。
bool shouldShowPeerPendingActions({
  required bool isPeerPending,
  required bool autoReceive,
}) =>
    isPeerPending && !autoReceive;

/// 图片预览可点门控：已完成 + 原图存在 + 有路径。
bool canPreviewImage({
  required bool isCompleted,
  required bool originalExists,
  required String? originalPath,
}) =>
    isCompleted && originalExists && originalPath != null;

/// 错误边框判定：失败或缺图统一红框（图片/文件气泡共用）。
bool shouldUseErrorBorder({required bool isFailed, required bool isMissing}) =>
    isFailed || isMissing;

/// 内容气泡底色（ARGB int，宿主再包 Color；去两处三元重复）。
int contentBubbleColor({required bool isMe, required bool isFile}) {
  if (!isMe) return 0xFFFFFFFF;
  return isFile ? 0xFFE3EDF7 : 0xFF95EC69;
}

/// 音频传输中气泡底色（与文字气泡同色系，单测收敛三元）。
int audioTransferBubbleColor({required bool isMe}) =>
    contentBubbleColor(isMe: isMe, isFile: false);

/// 聊天头像底色（ARGB int；对端蓝灰，本人青绿，去 4 处重复）。
int chatAvatarBg({required bool isMe}) =>
    isMe ? 0xFF009688 : 0xFF607D8B;

/// 音频失败重发可点门控：本人 + 有本地路径（纯判定可单测）。
bool canRetryAudioTap({required bool isMe, required String? filePath}) =>
    isMe && filePath != null;

/// 文件图标前景色（ARGB int；失败红，否则品牌蓝，去内联三元）。
int fileIconFg({required bool isFailed}) =>
    isFailed ? 0xFFE57373 : 0xFF5B9CF5;

/// 进度条值：>0 显示确定进度，否则不确定（null），去内联三元。
double? progressBarValue(double progress) => progress > 0 ? progress : null;

/// 传输任务进度回退：null 任务按 0 处理（语音重试 task 为空分支收敛）。
double taskProgressOrZero(double? progress) => progress ?? 0.0;

/// 进度刷新图/文案分支：图片走回退路径，否则沿用；音频恒标签。
/// 纯判定收敛 _updateTransferProgress 嵌套三元（可单测）。
String? resolveProgressImagePath({
  required bool isImage,
  required String? savedPath,
  required String? filePath,
  required String? fallback,
}) =>
    isImage ? (savedPath ?? filePath) : fallback;

/// 进度内容发送/接收分支：音频恒空（调用方填标签），否则按发送端选择。
bool isProgressSenderContent({
  required bool isAudio,
  required bool isSender,
}) =>
    !isAudio && isSender;

/// 缓存哨兵解码：Size.zero 表失败转 null，否则沿用（纯函数可单测）。
T? resolveCachedSize<T>(T? cached, T zero) =>
    cached == null ? null : (cached == zero ? null : cached);

/// 取消路由：taskId 优先走 cancelTransfer，否则 transferId 走 abort（_cancelTransfer 双键收敛）。
String resolveCancelRoute({String? taskId, String? transferId}) {
  if (taskId != null) return 'cancel';
  if (transferId != null) return 'abort';
  return 'none';
}

/// 音频判定：msg.type == audio（三处重复收敛）。
bool isAudioMessageType(String typeName) => typeName == 'audio';

/// 接收完成但不解压分支：已完成 + 非发送（_updateTransferProgress else-if 收敛）。
bool shouldLogNonExtractCompletion({
  required String stateName,
  required bool isSender,
}) =>
    stateName == 'completed' && !isSender;

/// 缩略图回填门控：有缩略图 + 已挂载 + 命中下标才 copyWith（三重 && 收敛）。
bool shouldApplyThumbnail({
  required String? thumbPath,
  required bool mounted,
  required int index,
}) =>
    thumbPath != null && mounted && index != -1;

/// 图片路径回退：imagePath > filePath（_updateTransferProgress ?? 收敛）。
String? resolveImagePathFallback(String? image, String? file) => image ?? file;

/// 首个非空 ID：a > b（transferId/taskId 双 ?? 链收敛）。
String? firstNonNullId(String? a, String? b) => a ?? b;

/// 进度内容类型：音频走标签，否则按发送端选发送/接收文案（嵌套三元收敛）。
String resolveProgressContentKind({
  required bool isAudio,
  required bool isSenderContent,
}) {
  if (isAudio) return 'audio';
  return isSenderContent ? 'send' : 'receive';
}

/// 时长双保险：<=0 需探测/直接返回（_updateAudioMeta 两处收敛）。
bool needsDurationProbe(int ms) => ms <= 0;
bool isInvalidDuration(int ms) => ms <= 0;

// E1：离开确认回退（dialog 取消 null 按留驻处理）。
bool leaveResultOrStay(bool? result) => result ?? false;

// E1：可空尺寸回退（图片解码失败回 Size.zero）。
T sizeOrZero<T>(T? size, T zero) => size ?? zero;

// E1：文本气泡复制可见（内容非空 + 非文件）。
bool shouldShowCopyForBubble({required String content, required bool isFile}) =>
    content.isNotEmpty && !isFile;

// E1：离线文字队列门控收敛（队列非空才 drain）。
bool hasQueuedText(bool isNotEmpty) => isNotEmpty;

// E1：图片消息类型判定（_buildChatBubble 内联 == 收敛）。
bool isImageMessageType(String t) => t == 'image';

// E1：文件消息类型判定（_buildChatBubble 内联 == 收敛）。
bool isFileMessageType(String t) => t == 'file';

// E1：图片气泡分支门控（图片且有本地路径才走图片气泡）。
bool shouldShowImageBubble({required bool isImage, required String? imagePath}) =>
    isImage && imagePath != null;

// E1：气泡对齐是否靠右（本人右侧，他人左侧；收敛 Row 三元）。
bool bubbleAlignmentIsEnd(bool isMe) => isMe;

// E1：头像半径收敛（原值 18.0）。
double avatarRadius() => 18.0;

// E1：气泡行纵向边距收敛（原值 8.0）。
double bubblePaddingV() => 8.0;

// E1：气泡间距收敛（头像与气泡间原值 8.0）。
double bubbleGap() => 8.0;

// E1：正文色收敛（Colors.black87 → ARGB int，宿主包 Color）。
int bubbleTextColor() => 0xDD000000;

// E1：次文案色收敛（Colors.grey[600] → 0xFF757575）。
int bubbleSubTextColor() => 0xFF757575;

// E1：错误文案色收敛（Colors.red → 0xFFF44336）。
int bubbleErrorColor() => 0xFFF44336;

// E1：文件边框色收敛（失败红 shade200，否则 black12；去内联三元）。
int bubbleFileBorderColor({required bool failed}) =>
    failed ? 0xFFEF9A9A : 0x1F000000;

// E1：内容气泡阴影色收敛（black alpha0.05 → 0x0D000000）。
int bubbleShadowColor() => 0x0D000000;

// E1：图片占位底色收敛（grey[100] → 0xFFF5F5F5）。
int imagePlaceholderBg() => 0xFFF5F5F5;

// E1：小取消按钮底色收敛（redAccent alpha0.15 → 0x26FF5252）。
int bubbleCancelBg() => 0x26FF5252;

// E1：取消图标色收敛（redAccent → 0xFFFF5252）。
int bubbleCancelFg() => 0xFFFF5252;

// E1：气泡纯白收敛（Colors.white → ARGB int）。
int bubbleWhite() => 0xFFFFFFFF;

// E1：占位图标灰收敛（grey[400] → 0xFFBDBDBD）。
int bubbleGrey400() => 0xFFBDBDBD;

// E1：次级灰收敛（grey[500] → 0xFF9E9E9E）。
int bubbleGrey500() => 0xFF9E9E9E;

// E1：进度轨底收敛（grey[200] → 0xFFEEEEEE）。
int bubbleGrey200() => 0xFFEEEEEE;

// E1：浅红文案收敛（red.shade400 → 0xFFEF5350）。
int bubbleRedLight() => 0xFFEF5350;

// E1：浅蓝文案收敛（blue.shade400 → 0xFF42A5F5）。
int bubbleBlueLight() => 0xFF42A5F5;

// E1：图片传输遮罩收敛（black alpha0.4 → 0x66000000）。
int imageMaskColor() => 0x66000000;

// E1：图片失败遮罩收敛（red alpha0.2 → 0x33F44336，宿主包 Color）。
int imageFailMaskColor() => 0x33F44336;

// E1：图片取消圆底收敛（redAccent alpha0.3 → 0x4DFF5252）。
int imageCancelBg() => 0x4DFF5252;

// E1：重试胶囊底收敛（white alpha0.85 → 0xD9FFFFFF）。
int retryChipBg() => 0xD9FFFFFF;

// E1：弱文案色收敛（Colors.black54 → ARGB int，宿主包 Color）。
int bubbleTextDim() => 0x8A000000;

// E1：文件状态文案色收敛（失败红，否则次文案灰；去内联三元）。
int bubbleStatusColor({required bool failed}) =>
    failed ? bubbleErrorColor() : bubbleSubTextColor();

// E1：品牌绿收敛（0xFF07C160，进度条/发送按钮共用）。
int bubbleBrandColor() => 0xFF07C160;

// E1：接受按钮绿收敛（Colors.green → 0xFF4CAF50）。
int bubbleAcceptColor() => 0xFF4CAF50;

// E1：发送进度 kind 判定。
bool isSendProgressKind(String k) => k == 'send';
// E1：音频进度 kind 判定。
bool isAudioProgressKind(String k) => k == 'audio';

// E1：预览路径断言收敛（!留Service层）。
String requirePreviewPath(String? p) => p!;

// E1：文字消息类型判定（内联==收敛）。
bool isTextMessageType(String t) => t == 'text';

// E1：重发内容分支收敛（音频走标签，否则文件文案）。
String resolveResendContent({
  required bool isAudio,
  required String audioLabel,
  required String sendContent,
}) =>
    isAudio ? audioLabel : sendContent;
