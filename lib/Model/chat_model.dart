enum MessageType { text, image, file }

/// 传输状态
enum TransferState {
  pending,     // 等待传输
  transferring, // 传输中
  completed,   // 已完成
  failed,      // 失败
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
  final String? filePath; // 本地文件路径
  final String? imagePath; // 图片本地路径（用于显示）
  final TransferState transferState; // 传输状态
  final String? taskId; // 关联的传输任务 ID

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
    this.transferState = TransferState.completed,
    this.taskId,
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
    TransferState? transferState,
    String? taskId,
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
      transferState: transferState ?? this.transferState,
      taskId: taskId ?? this.taskId,
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
      'transferState': transferState.index,
      'taskId': taskId,
    };
  }

  /// 从 JSON 反序列化
  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String,
      senderId: json['senderId'] as String,
      content: json['content'] as String,
      type: MessageType.values[json['type'] as int],
      timestamp: DateTime.parse(json['timestamp'] as String),
      isMe: json['isMe'] as bool,
      fileName: json['fileName'] as String?,
      fileSize: json['fileSize'] as String?,
      progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
      filePath: json['filePath'] as String?,
      imagePath: json['imagePath'] as String?,
      transferState: json['transferState'] != null
          ? TransferState.values[json['transferState'] as int]
          : TransferState.completed,
      taskId: json['taskId'] as String?,
    );
  }
}
