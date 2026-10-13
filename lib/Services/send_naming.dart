// E1：发送命名纯函数。从 ChatPage._sendFileFromPath/_handleSubmittedData/
// _sendAudioMessage/_sendFolderByPath/_generateThumbnail 抽出，可单测。

/// 发送消息 ID：重试沿用旧 ID，首发按毫秒戳生成。
String newSendMsgId({
  required bool isRetry,
  required String? existingId,
  required int nowMs,
}) =>
    isRetry ? existingId ?? 'send_$nowMs' : 'send_$nowMs';

/// 发送异常 ID。
String newSendErrId(int nowMs) => 'err_$nowMs';

/// 文字消息 ID（毫秒戳字符串）。
String newTextMsgId(int nowMs) => nowMs.toString();

/// 语音文件名/消息 ID。
String buildAudioFileName(int nowMs) => '语音消息_$nowMs.m4a';
String buildAudioMsgId(int nowMs) => 'audio_$nowMs';

/// 文件夹展示名去 .zip 后缀。
String stripZipSuffixForDisplay(String fileName) =>
    fileName.replaceAll(RegExp(r'\.zip$', caseSensitive: false), '');

/// 发送标签：文件夹 📁，文件 📤。
String sendErrLabel({required bool isFolder}) => isFolder ? '📁' : '📤';

/// 文件夹临时 zip 三件套：基名/zip名/带戳路径。
({String folderName, String zipFileName, String zipPath}) buildFolderZipPath({
  required String folderPath,
  required String tempDirPath,
  required int stampUs,
  required String basename,
}) {
  final zipFileName = '$basename.zip';
  return (
    folderName: basename,
    zipFileName: zipFileName,
    zipPath: '$tempDirPath/${stampUs}_$zipFileName',
  );
}

/// 缩略图名/路径。
String buildThumbName({required String fileName, required int nowMs}) =>
    'thumb_${fileName.hashCode.abs()}_$nowMs.jpg';
String buildThumbPath({required String thumbDir, required String thumbName}) =>
    '$thumbDir/$thumbName';

/// PIN 重试门控：被拒绝 + 原因 pinRequired/pinWrong + 首次才弹输入。
bool needsPinRetry({
  required bool rejected,
  required String? reason,
  required int attempt,
}) =>
    rejected &&
    (reason == 'pinRequired' || reason == 'pinWrong') &&
    attempt == 0;

/// 接收消息 ID。
String buildRecvMsgId(String taskId) => 'recv_$taskId';

/// 发送任务消息 ID（task.id 拼 send_ 前缀，四处重复收敛）。
String buildSendTaskMsgId(String taskId) => 'send_$taskId';

/// 接收路径回退：savedPath > filePath。
String? resolveRecvFilePath({required String? savedPath, String? filePath}) =>
    savedPath ?? filePath;

/// 接收图片路径：仅图片才回退，否则沿用旧值。
String? resolveRecvImagePath({
  required bool isImage,
  required String? savedPath,
  String? filePath,
}) =>
    isImage ? (savedPath ?? filePath) : null;

/// 旧端回退键：deviceId_fileName（四路凭证容器共用）。
String legacyAcceptKey(String deviceId, String fileName) =>
    '${deviceId}_$fileName';

/// 文件名兜底：null 回空串（十余处 `msg.fileName ?? ''` 收敛）。
String fileNameOrEmpty(String? fileName) => fileName ?? '';

// E1：文件名兜底（缺名按文件夹占位，避免解压/展示空名）。
String fileNameOrFolder(String? v) => v ?? 'folder';

// E1：文件名兜底（图片重发缺名占位）。
String fileNameOrImage(String? v) => v ?? 'image';

// E1：文件名兜底（文件重发缺名占位）。
String fileNameOrFile(String? v) => v ?? 'file';

// E1：文件名兜底（语音缺名占位）。
String fileNameOrAudio(String? v) => v ?? 'audio.m4a';

/// PIN 提示分支：pinWrong 走错误提示，否则走必填提示。
bool isPinWrongReason(String? reason) => reason == 'pinWrong';

/// 解压输出路径拼接：targetDir/safePath（两处手拼收敛，调用方再包 pth.join 亦可）。
String joinExtractPath(String dir, String safePath) => '$dir/$safePath';

// E1：文件路径存在判定收敛（恢复 hasPath/追认分支）。
bool hasFilePath(String? p) => p != null;

// E1：重发判定收敛（existingMsg 非空即重试）。
bool isRetrySend(Object? m) => m != null;

// E1：任务消息 ID 回退（有 taskId 拼 send_ 前缀，否则沿用原消息 ID）。
String taskMsgIdOr(String? taskId, String fallback) =>
    taskId != null ? buildSendTaskMsgId(taskId) : fallback;

// E1：批量文件数收敛。
int batchCount<T>(List<T> l) => l.length;

// E1：选择器单路径断言收敛（where已过滤null，!留Service层）。
String requireSinglePath(String? p) => p!;

// E1：重发路径断言收敛（!留Service层）。
String requireResendPath(String? p) => p!;

// E1：可空ID透传收敛（?.链收敛）。
String? nullableId(String? id) => id;

// E1：已有消息ID断言收敛（!留Service层）。
String requireExistingId(String? id) => id!;

// E1：已有消息断言收敛（!留Service层，泛型复用id/copyWith直接访问）。
T requireExisting<T extends Object>(T? v) => v!;

// E1：!收敛至Service（缩略图目录已判空，!留Service层）。
String requireThumbDir(String? d) => d!;

// E1：!收敛至Service（消息路径已判空，!留Service层）。
String requireMsgPath(String? p) => p!;

// E1：!收敛至Service（待发送文本已判空，!留Service层）。
String requirePendingText(String? s) => s!;

// E1：!收敛至Service（待发送文件夹已判空，!留Service层）。
String requirePendingFolder(String? s) => s!;
