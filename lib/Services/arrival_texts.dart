// E1：到达/pending/手动设备文案。从 ChatListPage newTaskStream 与
// fileNotify defer、手动添加残留抽出，可单测。

import 'package:wechat_lan_transfer/Model/chat_model.dart' show MessageType;

/// 到达标签：文件夹 📁，文件 📥。
String arrivalLabel(bool isFolder) => isFolder ? '📁' : '📥';

/// 到达消息类型：语音优先音频，否则图片/文件（嵌套三元收敛可单测）。
String resolveArrivalMsgType({required bool isVoice, required bool isImage}) =>
    isVoice ? 'audio' : (isImage ? 'image' : 'file');

/// 到达 kind 映射为消息枚举（chat_list 到达分支嵌套三元收敛）。
MessageType mapArrivalKindToMsgType(String msgKind) => msgKind == 'audio'
    ? MessageType.audio
    : (msgKind == 'image' ? MessageType.image : MessageType.file);

/// 初始接收消息类型：图片走 image，其余走 file（后续缓存覆盖元数据）。
MessageType resolveInitialRecvMsgType({required bool isImage}) =>
    isImage ? MessageType.image : MessageType.file;

/// file_notify 元数据语音标志：as bool 缺省 false（纯判定可单测）。
bool resolveIsVoice(Map<String, dynamic>? meta) =>
    (meta?['isVoice'] as bool?) ?? false;

/// 到达路径：savedPath 优先回退 filePath；图片非图恒 null。
String? resolveArrivalFilePath({String? savedPath, String? filePath}) =>
    savedPath ?? filePath;

/// 到达图片路径：仅图片回退，否则 null（chat_list 到达分支收敛）。
String? resolveArrivalImagePath({
  required bool isImage,
  String? savedPath,
  String? filePath,
}) =>
    isImage ? (savedPath ?? filePath) : null;

/// 到达批量后缀：语音恒空，否则会话批量后缀（纯函数可单测）。
String resolveArrivalBatchSuffix({
  required bool isVoice,
  required String? sessionId,
  required int? fileCount,
  required int? fileIndex,
  required String Function(String?, int?, int?) suffixOf,
}) =>
    isVoice ? '' : suffixOf(sessionId, fileCount, fileIndex);

/// 到达消息 ID。
String arrivalMsgId(String taskId) => 'recv_$taskId';

/// 到达内容：语音恒定，否则接收中 + 文件名 + 批量后缀。
String arrivalContent({
  required bool isVoice,
  required String label,
  required String fileName,
  required String batchSuffix,
}) {
  if (isVoice) return '语音消息';
  if (batchSuffix.isNotEmpty) return '$label 接收中: $fileName$batchSuffix';
  return '$label 接收中: $fileName (0%)';
}

/// pending 内容：标签 + 等待接收 + 文件名 + 批量后缀。
String pendingContent({
  required String emoji,
  required String fileName,
  required String batchSuffix,
}) =>
    '$emoji 等待接收: $fileName$batchSuffix';

/// 通知 toast 前缀：文件夹/文件。
String notifyToastLabel(bool isFolder) => isFolder ? '📁文件夹' : '📥文件';

/// 手动设备名/状态文案。
String manualName(bool ok) => ok ? '手动设备' : '手动设备（未响应）';
String manualLastMsg(bool ok) =>
    ok ? '手动添加：在线' : '手动添加：未响应，请检查端口';

// E1：全局进度日志后缀收敛（成功 completed，否则 failed）。
String progressLogSuffix({required bool isSuccess}) =>
    isSuccess ? 'completed' : 'failed';

// E1：接收弹窗接受判定收敛（true 即同意）。
bool isDialogAccepted(bool? v) => v == true;

// E1：批量会话数解析收敛（task 优先，元数据兜底）。
int? resolveSessCount(int? a, Map? m) => a ?? (m?['fileCount'] as int?);

// E1：语音时长解析收敛（缺省 0）。
int resolveDurationMs(Map? m) => (m?['durationMs'] as num?)?.toInt() ?? 0;

// E1：语音波形解析收敛（缺省 null）。
String? resolveWaveform(Map? m) => m?['waveformData'] as String?;

// E1：弹窗明确拒绝判定收敛（false 即拒绝，null/true 否）。
bool isExplicitReject(bool? v) => v == false;

// E1：会话文件序号回退收敛（direct 优先，元数据 fileIndex 兜底）。
int? resolveSessIndex(int? direct, Map? meta) =>
    direct ?? (meta?['fileIndex'] as int?);

// E1：会话 ID 回退收敛（direct 优先，元数据 sessionId 兜底）。
String? resolveSessId(String? direct, Map? meta) =>
    direct ?? (meta?['sessionId'] as String?);

// E1：空间不足拒绝判定收敛（reason == noSpace）。
bool isNoSpaceReject(String? r) => r == 'noSpace';

// E1：新建/已有展示文案回退收敛（新建用新文案，否则沿用）。
String resolveLastMsg(String? cur, String fallback) => cur ?? fallback;
