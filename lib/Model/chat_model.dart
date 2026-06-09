enum MessageType { text, image, file }

class ChatMessage {
  final String id;
  final String senderId;
  final String content;
  final MessageType type;
  final DateTime timestamp;
  final bool isMe;

  // 专门为局域网文件加的拓展属性
  final String? fileName;
  final String? fileSize;
  final double progress; // 传输进度 0.0 ~ 1.0

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
  });
}
