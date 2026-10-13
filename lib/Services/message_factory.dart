// E1：消息工厂纯函数。从 ChatPage/ChatListPage 内联 ChatMessage 构造抽出，
// 可单测。时间经 now 注入；文件大小文案由调用方格式化后传入；持久化/setState 留宿主。

import 'package:wechat_lan_transfer/Model/chat_model.dart';

/// 外发文字消息（sending，等待 ACK）。
ChatMessage buildOutgoingText({
  required String msgId,
  required String text,
  required DateTime now,
}) =>
    ChatMessage(
      id: msgId,
      senderId: 'me',
      content: text,
      type: MessageType.text,
      timestamp: now,
      isMe: true,
      transferState: TransferState.sending,
    );

/// 入站文字消息（已落盘展示用）。
ChatMessage buildIncomingText({
  required String id,
  required String senderId,
  required String content,
  required DateTime now,
}) =>
    ChatMessage(
      id: id,
      senderId: senderId,
      content: content,
      type: MessageType.text,
      timestamp: now,
      isMe: false,
    );

/// 外发语音消息（pending，等待对方 accept）。
ChatMessage buildOutgoingAudio({
  required String msgId,
  required String fileName,
  required String fileSizeText,
  required String filePath,
  required String content,
  required String transferId,
  required int durationMs,
  required String? waveformData,
  required DateTime now,
}) =>
    ChatMessage(
      id: msgId,
      senderId: 'me',
      content: content,
      type: MessageType.audio,
      fileName: fileName,
      fileSize: fileSizeText,
      filePath: filePath,
      timestamp: now,
      isMe: true,
      progress: 0.0,
      transferState: TransferState.pending,
      transferId: transferId,
      durationMs: durationMs,
      waveformData: waveformData,
    );

/// 外发文件/图片 pending 消息（首发；重发由调用方 copyWith）。
ChatMessage buildOutgoingFile({
  required String msgId,
  required String content,
  required bool isImage,
  required String displayName,
  required String fileSizeText,
  required String filePath,
  required String? thumbPath,
  required String transferId,
  required String? sessionId,
  required bool isFolder,
  required DateTime now,
}) =>
    ChatMessage(
      id: msgId,
      senderId: 'me',
      content: content,
      type: isImage ? MessageType.image : MessageType.file,
      fileName: displayName,
      fileSize: fileSizeText,
      filePath: filePath,
      imagePath: isImage ? filePath : null,
      thumbnailPath: thumbPath,
      timestamp: now,
      isMe: true,
      progress: 0.0,
      transferState: TransferState.pending,
      transferId: transferId,
      sessionId: sessionId,
      isFolder: isFolder,
    );

/// 发送失败占位消息（文件不存在时）。
ChatMessage buildSendMissingFile({
  required String id,
  required String content,
  required bool isImage,
  required String displayName,
  required String filePath,
  required bool isFolder,
  required DateTime now,
}) =>
    ChatMessage(
      id: id,
      senderId: 'me',
      content: content,
      type: isImage ? MessageType.image : MessageType.file,
      fileName: displayName,
      filePath: filePath,
      imagePath: isImage ? filePath : null,
      timestamp: now,
      isMe: true,
      transferState: TransferState.failed,
      isFolder: isFolder,
    );

/// 接收侧 pending 消息（非自动接收，等待用户点接收/拒绝）。
ChatMessage buildInboundPending({
  required String pendingId,
  required String senderIp,
  required String content,
  required bool isVoice,
  required String fileName,
  required String? fileSizeText,
  required bool isFolder,
  required String? transferId,
  required String? sessionId,
  required int durationMs,
  required String? waveformData,
  required DateTime now,
}) =>
    ChatMessage(
      id: pendingId,
      senderId: senderIp,
      content: content,
      type: isVoice ? MessageType.audio : MessageType.file,
      timestamp: now,
      isMe: false,
      fileName: fileName,
      fileSize: fileSizeText,
      isFolder: isFolder,
      transferState: TransferState.pending,
      transferId: transferId,
      sessionId: sessionId,
      filePath: null,
      durationMs: durationMs,
      waveformData: waveformData,
    );

/// 接收侧到达消息（TCP newTask，transferring）。
ChatMessage buildInboundArrival({
  required String id,
  required String senderIp,
  required String content,
  required MessageType type,
  required String fileName,
  required String? fileSizeText,
  required String? filePath,
  required String? imagePath,
  required String taskId,
  required String? transferId,
  required String? sessionId,
  required bool isFolder,
  required int durationMs,
  required String? waveformData,
  required DateTime now,
}) =>
    ChatMessage(
      id: id,
      senderId: senderIp,
      content: content,
      type: type,
      timestamp: now,
      isMe: false,
      fileName: fileName,
      fileSize: fileSizeText,
      filePath: filePath,
      imagePath: imagePath,
      progress: 0.0,
      transferState: TransferState.transferring,
      taskId: taskId,
      transferId: transferId,
      sessionId: sessionId,
      isFolder: isFolder,
      durationMs: durationMs,
      waveformData: waveformData,
    );
