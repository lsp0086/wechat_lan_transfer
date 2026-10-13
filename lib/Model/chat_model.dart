enum MessageType { text, image, file, audio }

/// 传输状态
enum TransferState {
  pending,      // 等待传输
  transferring, // 传输中（文件传输进度中）
  completed,    // 已完成
  failed,       // 失败
  sending,      // 发送中（等待对方 ACK 确认）
  blocked,      // 被对方拒收（对方已拉黑）
}

class ChatMessage {
  final String id;
  final String senderId;
  final String content;
  final MessageType type;
  final DateTime timestamp;
  final bool isMe;

  // 文件/图片相关字段
  final String? fileName;
  final String? fileSize;
  final double progress; // 传输进度 0.0 ~ 1.0
  final String? filePath; // 本地文件路径（原图/文件保存路径）
  final String? imagePath; // 图片本地路径（用于显示，已废弃，保留兼容）
  final String? thumbnailPath; // 缩略图本地路径（统一用于气泡显示）
  final TransferState transferState; // 传输状态
  final String? taskId; // 关联的传输任务 ID
  /// P0-4：端到端握手 ID（UDP notify/accept/reject + TCP header 透传），解决同名并发顶掉
  final String? transferId;
  // T2：批量会话 ID（多文件一次同意，同一批共享；单文件为空）
  final String? sessionId;

  // 语音相关字段
  final int durationMs; // 音频时长（毫秒）
  final String? waveformData; // 声波图振幅数据（JSON 编码的 List<double>）

  // 文件夹标记（发送/接收的压缩包需要解压为文件夹）
  final bool isFolder;

  ChatMessage({
    required this.id,
    required this.senderId,
    required this.content,
    required this.type,
    required this.timestamp,
    required this.isMe,
    this.fileName,
    this.fileSize,
    this.progress = 0.0,
    this.filePath,
    this.imagePath,
    this.thumbnailPath,
    this.transferState = TransferState.completed,
    this.taskId,
    this.transferId,
    this.sessionId,
    this.durationMs = 0,
    this.waveformData,
    this.isFolder = false,
  });

  /// 创建一个副本，更新部分字段
  ChatMessage copyWith({
    String? id,
    String? senderId,
    String? content,
    MessageType? type,
    DateTime? timestamp,
    bool? isMe,
    String? fileName,
    String? fileSize,
    double? progress,
    String? filePath,
    String? imagePath,
    String? thumbnailPath,
    TransferState? transferState,
    String? taskId,
    String? transferId,
    String? sessionId,
    int? durationMs,
    String? waveformData,
    bool? isFolder,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      senderId: senderId ?? this.senderId,
      content: content ?? this.content,
      type: type ?? this.type,
      timestamp: timestamp ?? this.timestamp,
      isMe: isMe ?? this.isMe,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      progress: progress ?? this.progress,
      filePath: filePath ?? this.filePath,
      imagePath: imagePath ?? this.imagePath,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      transferState: transferState ?? this.transferState,
      taskId: taskId ?? this.taskId,
      transferId: transferId ?? this.transferId,
      sessionId: sessionId ?? this.sessionId,
      durationMs: durationMs ?? this.durationMs,
      waveformData: waveformData ?? this.waveformData,
      isFolder: isFolder ?? this.isFolder,
    );
  }

  /// 序列化为 JSON（用于持久化）
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'senderId': senderId,
      'content': content,
      'type': type.index,
      'timestamp': timestamp.toIso8601String(),
      'isMe': isMe,
      'fileName': fileName,
      'fileSize': fileSize,
      'progress': progress,
      'filePath': filePath,
      'imagePath': imagePath,
      'thumbnailPath': thumbnailPath,
      'transferState': transferState.index,
      'taskId': taskId,
      'transferId': transferId,
      'sessionId': sessionId,
      'durationMs': durationMs,
      'waveformData': waveformData,
      'isFolder': isFolder,
    };
  }

  /// 从 JSON 反序列化
  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final typeIdx = json['type'] as int? ?? MessageType.text.index;
    final transferStateIdx = json['transferState'] as int?;
    return ChatMessage(
      id: json['id'] as String,
      senderId: json['senderId'] as String,
      content: json['content'] as String,
      type: typeIdx >= 0 && typeIdx < MessageType.values.length
          ? MessageType.values[typeIdx]
          : MessageType.text,
      timestamp: DateTime.parse(json['timestamp'] as String),
      isMe: json['isMe'] as bool,
      fileName: json['fileName'] as String?,
      fileSize: json['fileSize'] as String?,
      progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
      filePath: json['filePath'] as String?,
      imagePath: json['imagePath'] as String?,
      thumbnailPath: json['thumbnailPath'] as String?,
      transferState: transferStateIdx != null &&
              transferStateIdx >= 0 &&
              transferStateIdx < TransferState.values.length
          ? TransferState.values[transferStateIdx]
          : TransferState.completed,
      taskId: json['taskId'] as String?,
      transferId: json['transferId'] as String?,
      sessionId: json['sessionId'] as String?,
      durationMs: (json['durationMs'] as int?) ?? 0,
      waveformData: json['waveformData'] as String?,
      isFolder: json['isFolder'] as bool? ?? false,
    );
  }
}
