import 'dart:async';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import '../Model/chat_model.dart';
import '../Services/file_transfer_service.dart';
import '../Services/message_cache_service.dart';
import '../Services/udp_message_service.dart';
import 'chat_more_page.dart';
import 'chat_info_page.dart';

class ChatPage extends StatefulWidget {
  final String title;
  final String id;
  final UdpMessageService msgService;
  final String myDeviceName;

  const ChatPage({super.key, 
    required this.id,
    required this.title,
    required this.msgService,
    required this.myDeviceName,
  });

  @override
  _ChatPageState createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  List<ChatMessage> chatData = [];
  List<String> _emojiList = [];
  bool _isVoice = false;
  bool _isMore = false;
  bool _emojiState = false;

  final TextEditingController _textController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  // 面板可见性由 _emojiState 和 _isMore 直接决定

  // 服务层
  final FileTransferService _transferService = FileTransferService();
  final MessageCacheService _cacheService = MessageCacheService();
  final ImagePicker _imagePicker = ImagePicker();

  // 自动接收文件（默认开启），从 ChatInfoPage 同步
  bool _autoReceive = true;

  StreamSubscription<FileTransferTask>? _progressSubscription;
  StreamSubscription<FileTransferTask>? _newTaskSubscription;
  StreamSubscription<ReceivedMessage>? _msgSubscription;

  @override
  void initState() {
    super.initState();
    // 精选常用 emoji，避免 Unicode 空白区间产生空表情
    _emojiList = _buildEmojiList();

    // 监听焦点变化：键盘弹起时自动收起面板
    _focusNode.addListener(_onFocusChanged);

    _initChat();
  }

  void _onFocusChanged() {
    setState(() {
      if (_focusNode.hasFocus) {
        _emojiState = false;
        _isMore = false;
      }
    });
  }

  Future<void> _initChat() async {
    // 1. 先设置好所有监听，不阻塞 UI
    _newTaskSubscription = _transferService.newTaskStream.listen((task) {
      _onFileReceived(task);
    });
    _progressSubscription = _transferService.progressStream.listen((task) {
      _updateTransferProgress(task);
    });
    _msgSubscription = widget.msgService.messageStream.listen((msg) {
      _handleIncomingMessage(msg);
    });

    // 2. 从缓存加载聊天记录（不依赖网络，先显示）
    final cachedMessages = await _cacheService.loadMessages(widget.id);
    if (cachedMessages.isNotEmpty) {
      // 从缓存恢复后，将所有传输中/pending 的消息标记为失败
      // 避免之前异常退出导致的消息卡在"传输中"状态
      bool hasChanges = false;
      final fixedMessages = cachedMessages.map((m) {
        if (m.transferState == TransferState.transferring ||
            m.transferState == TransferState.pending) {
          hasChanges = true;
          return m.copyWith(
            content: m.isMe
                ? '📤 发送中断: ${m.fileName ?? ""}'
                : '📥 接收中断: ${m.fileName ?? ""}',
            transferState: TransferState.failed,
          );
        }
        return m;
      }).toList();
      setState(() {
        chatData = fixedMessages;
      });
      // 写回缓存，避免下次进入时重复处理
      if (hasChanges) {
        await _cacheService.saveMessages(widget.id, fixedMessages);
      }
    } else {
      final initMsg = ChatMessage(
        id: 'init_${DateTime.now().millisecondsSinceEpoch}',
        senderId: widget.id,
        content: '局域网传输通道已建立。正在与设备 [${widget.title}] 连接...',
        type: MessageType.text,
        timestamp: DateTime.now(),
        isMe: false,
      );
      setState(() {
        chatData = [initMsg];
      });
      _cacheService.appendMessage(widget.id, initMsg);
    }
    _scrollToBottom();

    // 3. 后台启动文件接收服务器（可能慢，不阻塞 UI）
    _transferService.startServer().catchError((e) {
      debugPrint('启动文件服务器失败: $e');
    });
  }

  // ========== 处理 UDP 消息通道的入站消息 ==========
  void _handleIncomingMessage(ReceivedMessage msg) {
    debugPrint('[ChatPage] 收到入站消息: cmd=${msg.cmd}, senderIp=${msg.senderIp}, currentChatId=${widget.id}');
    // 只处理来自当前对话设备的消息
    if (msg.senderIp != widget.id) {
      debugPrint('[ChatPage] 消息来自 ${msg.senderIp}，当前对话是 ${widget.id}，忽略');
      return;
    }

    switch (msg.cmd) {
      case UdpCmd.textMessage:
        _onTextMessageReceived(msg);
        break;
      case UdpCmd.fileNotify:
        _onFileNotifyReceived(msg);
        break;
      case UdpCmd.fileAccept:
        // 发送方收到接收确认：可能是初始确认（TCP 已自动开始），
        // 也可能是接收方请求重新发送之前被拒绝的文件
        _onFileAcceptReceived(msg);
        break;
      case UdpCmd.fileReject:
        _onFileRejectReceived(msg);
        break;
    }
  }

  /// 收到文字消息
  void _onTextMessageReceived(ReceivedMessage msg) {
    final newMsg = ChatMessage(
      id: 'recv_text_${DateTime.now().millisecondsSinceEpoch}',
      senderId: widget.id,
      content: msg.payload['content'] as String? ?? '',
      type: MessageType.text,
      timestamp: DateTime.now(),
      isMe: false,
    );

    setState(() {
      chatData.add(newMsg);
    });
    _cacheService.appendMessage(widget.id, newMsg);
    _scrollToBottom();
  }

  /// 收到文件传输通知（对方即将通过 TCP 发文件过来）
  void _onFileNotifyReceived(ReceivedMessage msg) {
    final fileName = msg.payload['fileName'] as String? ?? '未知文件';

    // 发送确认回复，让发送方开始 TCP 传输
    widget.msgService.sendFileAccept(
      targetIp: widget.id,
      originalFileName: fileName,
    );

    // 不在这里创建消息，等 TCP 层 _onFileReceived 时统一创建唯一的一条消息
    // 避免出现 UDP 通知消息和 TCP 传输消息两条重复的 bug
  }

  /// 收到文件接收确认（接收方请求重新发送之前被拒绝的文件）
  void _onFileAcceptReceived(ReceivedMessage msg) {
    final fileName = msg.payload['fileName'] as String? ?? '';

    // 查找最近一条发送给该设备的、该文件名的、失败的消息，尝试重新发送
    ChatMessage? targetMsg;
    int targetIndex = -1;
    for (int i = chatData.length - 1; i >= 0; i--) {
      final m = chatData[i];
      if (m.isMe &&
          (m.type == MessageType.file || m.type == MessageType.image) &&
          m.fileName == fileName &&
          m.transferState == TransferState.failed &&
          m.filePath != null) {
        targetMsg = m;
        targetIndex = i;
        break;
      }
    }

    if (targetMsg != null) {
      debugPrint('[ChatPage] 收到重新发送请求: $fileName，重新发送');
      // 更新消息为传输中
      setState(() {
        chatData[targetIndex] = targetMsg!.copyWith(
          content: '📤 重新发送中: ${targetMsg.fileName}',
          transferState: TransferState.transferring,
          progress: 0.0,
        );
      });
      _cacheService.updateMessage(widget.id, targetMsg.id, chatData[targetIndex]);

      // 重新发送
      _sendFileFromPath(
        targetMsg.filePath!,
        targetMsg.fileName ?? 'file',
        isImage: targetMsg.type == MessageType.image,
      );
    }
  }

  /// 收到文件传输拒绝（接收方拒绝了传输）
  void _onFileRejectReceived(ReceivedMessage msg) {
    final fileName = msg.payload['fileName'] as String? ?? '未知文件';

    // 查找最近一条发送给该设备的文件消息，将其标记为失败（红色气泡）
    setState(() {
      for (int i = chatData.length - 1; i >= 0; i--) {
        final m = chatData[i];
        if (m.isMe &&
            m.type == MessageType.file &&
            m.fileName == fileName &&
            m.transferState == TransferState.transferring) {
          chatData[i] = m.copyWith(
            content: '📤 对方拒绝接收: $fileName',
            transferState: TransferState.failed,
          );
          _cacheService.updateMessage(widget.id, m.id, chatData[i]);
          break;
        }
      }
    });

    debugPrint('[ChatPage] 对方拒绝接收文件: $fileName');
  }

  // ========== 文件接收回调（TCP 层实际开始接收文件） ==========
  void _onFileReceived(FileTransferTask task) {
    // 防止同一个 taskId 重复创建消息气泡
    final existingIndex = chatData.indexWhere((m) => m.taskId == task.id);
    if (existingIndex != -1) {
      debugPrint('[ChatPage] taskId=${task.id} 已存在消息，跳过重复创建');
      return;
    }

    final msg = ChatMessage(
      id: 'recv_${task.id}',
      senderId: widget.id,
      content: '📥 正在接收: ${task.fileName}',
      type: MessageType.file,
      timestamp: DateTime.now(),
      isMe: false,
      fileName: task.fileName,
      fileSize: _formatFileSize(task.fileSize),
      filePath: task.savedPath ?? task.filePath,
      progress: 0.0,
      transferState: TransferState.transferring,
      taskId: task.id,
    );

    setState(() {
      chatData.add(msg);
    });
    _cacheService.appendMessage(widget.id, msg);
    _scrollToBottom();
  }

  // ========== 取消传输 ==========
  void _cancelTransfer(ChatMessage msg) {
    if (msg.taskId == null) return;

    // 取消 TCP 传输任务
    _transferService.cancelTransfer(msg.taskId!);

    // 如果是我发起的，通知对方拒绝接收
    if (msg.isMe) {
      widget.msgService.sendFileReject(
        targetIp: widget.id,
        originalFileName: msg.fileName ?? '',
      );
    }

    // 更新本地消息为红色气泡
    setState(() {
      final index = chatData.indexWhere((m) => m.id == msg.id);
      if (index != -1) {
        chatData[index] = msg.copyWith(
          content: msg.isMe
              ? '📤 已取消发送: ${msg.fileName ?? ''}'
              : '📥 已拒绝接收: ${msg.fileName ?? ''}',
          transferState: TransferState.failed,
        );
        _cacheService.updateMessage(widget.id, msg.id, chatData[index]);
      }
    });
  }

  // ========== 更新传输进度 ==========
  void _updateTransferProgress(FileTransferTask task) {
    final index = chatData.indexWhere((m) => m.taskId == task.id);
    if (index == -1) return;

    // 防止已完成/已失败的消息被回退到传输中状态
    final currentMsg = chatData[index];
    if (currentMsg.transferState == TransferState.completed ||
        currentMsg.transferState == TransferState.failed) {
      return;
    }

    TransferState state;
    switch (task.status) {
      case TransferStatus.transferring:
        state = TransferState.transferring;
        break;
      case TransferStatus.completed:
        state = TransferState.completed;
        break;
      case TransferStatus.failed:
      case TransferStatus.cancelled:
        state = TransferState.failed;
        break;
      default:
        state = TransferState.pending;
    }

    final updatedMsg = chatData[index].copyWith(
      progress: task.progress,
      transferState: state,
      filePath: task.savedPath ?? task.filePath,
      content: task.isSender
          ? _buildFileSendContent(task)
          : _buildFileReceiveContent(task),
    );

    setState(() {
      chatData[index] = updatedMsg;
    });
    _cacheService.updateMessage(widget.id, updatedMsg.id, updatedMsg);
  }

  String _buildFileSendContent(FileTransferTask task) {
    switch (task.status) {
      case TransferStatus.completed:
        return '📤 发送成功: ${task.fileName}';
      case TransferStatus.failed:
        return '📤 发送失败: ${task.fileName}';
      case TransferStatus.transferring:
        return '📤 发送中: ${task.fileName} (${(task.progress * 100).toStringAsFixed(0)}%)';
      default:
        return '📤 ${task.fileName}';
    }
  }

  String _buildFileReceiveContent(FileTransferTask task) {
    switch (task.status) {
      case TransferStatus.completed:
        return '📥 接收完成: ${task.fileName}';
      case TransferStatus.failed:
        return '📥 接收失败: ${task.fileName}';
      case TransferStatus.transferring:
        return '📥 接收中: ${task.fileName} (${(task.progress * 100).toStringAsFixed(0)}%)';
      default:
        return '📥 ${task.fileName}';
    }
  }

  // ========== 文件选择器 ==========
  Future<void> _openFilePicker() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
      );

      if (result != null && result.files.single.path != null) {
        PlatformFile file = result.files.single;

        // 先通过 UDP 通知对方即将发送文件
        await widget.msgService.sendFileNotify(
          targetIp: widget.id,
          fileName: file.name,
          fileSize: file.size,
          senderName: widget.myDeviceName,
        );

        // 短暂延迟等对方确认，然后开始 TCP 传输
        await Future.delayed(const Duration(milliseconds: 300));

        // 发送文件
        final task = await _transferService.sendFile(
          filePath: file.path!,
          targetIp: widget.id,
          customFileName: file.name,
        );

        if (task != null) {
          final fileMsg = ChatMessage(
            id: 'send_${task.id}',
            senderId: 'me',
            content: _buildFileSendContent(task),
            type: MessageType.file,
            fileName: file.name,
            fileSize: _formatFileSize(file.size),
            filePath: file.path,
            timestamp: DateTime.now(),
            isMe: true,
            progress: task.progress,
            transferState: TransferState.transferring,
            taskId: task.id,
          );

          setState(() {
            chatData.add(fileMsg);
          });
          _cacheService.appendMessage(widget.id, fileMsg);
          _scrollToBottom();
        }
      }
    } catch (e) {
      debugPrint("文件选择异常: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('文件选择失败: $e')),
        );
      }
    }
  }

  // ========== 图片选择器（相册）- 用 file_picker 选择原始文件 ==========
  // 避免 image_picker 对 GIF 等格式重新编码导致模糊/丢失动画
  Future<void> _pickImageFromGallery() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          'jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp',
          'heic', 'heif', 'svg',
        ],
        allowMultiple: false,
      );

      if (result != null && result.files.single.path != null) {
        final file = result.files.single;
        final ext = file.extension?.toLowerCase() ?? '';
        final isImage = [
          'jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic', 'heif', 'svg'
        ].contains(ext);

        await _sendFileFromPath(file.path!, file.name, isImage: isImage);
      }
    } catch (e) {
      debugPrint("选择图片失败: $e");
    }
  }

  // ========== 拍照 ==========
  Future<void> _takePhoto() async {
    try {
      final XFile? photo = await _imagePicker.pickImage(
        source: ImageSource.camera,
        imageQuality: 90,
      );

      if (photo != null) {
        await _sendFileFromPath(photo.path, photo.name, isImage: true);
      }
    } catch (e) {
      debugPrint("拍照失败: $e");
    }
  }

  // ========== 发送文件（通用） ==========
  Future<void> _sendFileFromPath(String filePath, String fileName, {bool isImage = false}) async {
    try {
      final file = File(filePath);
      final fileSize = await file.length();

      // 先通过 UDP 通知对方
      await widget.msgService.sendFileNotify(
        targetIp: widget.id,
        fileName: fileName,
        fileSize: fileSize,
        senderName: widget.myDeviceName,
      );

      await Future.delayed(const Duration(milliseconds: 300));

      final task = await _transferService.sendFile(
        filePath: filePath,
        targetIp: widget.id,
        customFileName: fileName,
      );

      // 创建一条文件消息，绑定 taskId，进度由 _progressSubscription 统一更新
      if (task != null) {
        final fileMsg = ChatMessage(
          id: 'send_${task.id}',
          senderId: 'me',
          content: _buildFileSendContent(task),
          type: isImage ? MessageType.image : MessageType.file,
          fileName: fileName,
          fileSize: _formatFileSize(fileSize),
          filePath: filePath,
          imagePath: isImage ? filePath : null,
          timestamp: DateTime.now(),
          isMe: true,
          progress: task.progress,
          transferState: TransferState.transferring,
          taskId: task.id,
        );

        setState(() {
          chatData.add(fileMsg);
        });
        _cacheService.appendMessage(widget.id, fileMsg);
        _scrollToBottom();
      }
    } catch (e) {
      debugPrint("发送文件失败: $e");
      if (mounted) {
        final errMsg = ChatMessage(
          id: 'err_${DateTime.now().millisecondsSinceEpoch}',
          senderId: 'me',
          content: '📤 发送失败: $fileName',
          type: isImage ? MessageType.image : MessageType.file,
          fileName: fileName,
          filePath: filePath,
          imagePath: isImage ? filePath : null,
          timestamp: DateTime.now(),
          isMe: true,
          transferState: TransferState.failed,
        );

        setState(() {
          chatData.add(errMsg);
        });
        _cacheService.appendMessage(widget.id, errMsg);
        _scrollToBottom();
      }
    }
  }

  void insertText(String text) {
    final TextEditingValue value = _textController.value;
    final int start = value.selection.baseOffset;
    int end = value.selection.extentOffset;
    if (value.selection.isValid) {
      String newText = '';
      if (value.selection.isCollapsed) {
        if (end > 0) {
          newText += value.text.substring(0, end);
        }
        newText += text;
        if (value.text.length > end) {
          newText += value.text.substring(end, value.text.length);
        }
      } else {
        newText = value.text.replaceRange(start, end, text);
        end = start;
      }

      _textController.value = value.copyWith(
        text: newText,
        selection: value.selection.copyWith(
          baseOffset: end + text.length,
          extentOffset: end + text.length,
        ),
      );
    } else {
      _textController.value = TextEditingValue(
        text: text,
        selection: TextSelection.fromPosition(
          TextPosition(offset: text.length),
        ),
      );
    }
  }

  void _handleSubmittedData(String text) {
    if (text.trim().isEmpty) return;
    _textController.clear();

    debugPrint('[ChatPage] ====== 发送文字消息 ======');
    debugPrint('[ChatPage] 目标IP: ${widget.id}');
    debugPrint('[ChatPage] 内容: "$text"');
    debugPrint('[ChatPage] 消息服务状态: running=${widget.msgService.isRunning}, localIP=${widget.msgService.localIP}');

    final newMsg = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      senderId: 'me',
      content: text,
      type: MessageType.text,
      timestamp: DateTime.now(),
      isMe: true,
    );

    setState(() {
      chatData.add(newMsg);
    });
    _cacheService.appendMessage(widget.id, newMsg);
    _scrollToBottom();

    // 通过网络发送文字消息
    widget.msgService.sendTextMessage(
      targetIp: widget.id,
      content: text,
      senderName: widget.myDeviceName,
    );
  }

  void onTapMore() {
    setState(() {
      _isVoice = false;
      _emojiState = false;
      if (_isMore) {
        _isMore = false;
        _focusNode.requestFocus();
      } else {
        if (_focusNode.hasFocus) {
          _focusNode.unfocus();
        }
        _isMore = true;
      }
    });
  }

  void onTapEmoji() {
    setState(() {
      _isVoice = false;
      _isMore = false;
      if (_emojiState) {
        _emojiState = false;
        _focusNode.requestFocus();
      } else {
        if (_focusNode.hasFocus) {
          _focusNode.unfocus();
        }
        _emojiState = true;
      }
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    // 面板高度固定为屏幕高度的 0.4 倍，不再依赖键盘高度
    final panelHeight = MediaQuery.of(context).size.height * 0.4;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: const Color(0xFFEDF0F3),
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: const Color(0xFFF3F3F3),
        elevation: 0.5,
        iconTheme: const IconThemeData(color: Colors.black87),
        titleTextStyle: const TextStyle(
          color: Colors.black87,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.more_horiz),
            onPressed: () async {
              final result = await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                  builder: (_) => ChatInfoPage(
                    id: widget.id,
                    name: widget.title,
                    cacheService: _cacheService,
                    initialAutoReceive: _autoReceive,
                  ),
                ),
              );
              if (result != null && mounted) {
                setState(() {
                  _autoReceive = result;
                });
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () {
                _focusNode.unfocus();
              },
              child: ListView.builder(
                controller: _scrollController,
                itemCount: chatData.length,
                padding: const EdgeInsets.all(15.0),
                itemBuilder: (context, index) {
                  return _buildChatBubble(chatData[index]);
                },
              ),
            ),
          ),
          _buildInputBar(),
          Visibility(
            visible: _emojiState,
            child: Container(
              height: panelHeight,
              color: const Color(0xFFF6F6F6),
              child: _buildEmojiWidget(),
            ),
          ),
          Visibility(
            visible: _isMore,
            child: Container(
              height: panelHeight,
              color: const Color(0xFFF6F6F6),
              child: ChatMorePage(
                id: widget.id,
                onFileSelected: _openFilePicker,
                onPickImage: _pickImageFromGallery,
                onTakePhoto: _takePhoto,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ========== 聊天气泡（支持文字/图片/文件/进度条） ==========
  Widget _buildChatBubble(ChatMessage msg) {
    final bool isImage = msg.type == MessageType.image;
    final bool isFile = msg.type == MessageType.file;
    final bool isTransferring =
        msg.transferState == TransferState.transferring;
    final bool isFailed = msg.transferState == TransferState.failed;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment:
            msg.isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!msg.isMe)
            CircleAvatar(
              backgroundColor: Colors.blueGrey,
              radius: 18,
              child: Text(
                widget.title.isNotEmpty ? widget.title.substring(0, 1) : "机",
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
          const SizedBox(width: 8),
          Flexible(
            child: isImage && msg.imagePath != null
                ? _buildImageBubble(msg)
                : _buildContentBubble(msg, isFile, isTransferring, isFailed),
          ),
          const SizedBox(width: 8),
          if (msg.isMe)
            const CircleAvatar(
              backgroundColor: Colors.teal,
              radius: 18,
              child: Text(
                '我',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
        ],
      ),
    );
  }

  /// 图片气泡（支持传输状态叠加层）
  Widget _buildImageBubble(ChatMessage msg) {
    final bool isTransferring = msg.transferState == TransferState.transferring;
    final bool isFailed = msg.transferState == TransferState.failed;

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.55,
          maxHeight: 220,
        ),
        decoration: BoxDecoration(
          border: Border.all(
            color: isFailed ? Colors.red.shade200 : Colors.black12,
            width: 0.5,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Image.file(
              File(msg.imagePath!),
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) {
                return Container(
                  height: 120,
                  width: 120,
                  color: Colors.grey[200],
                  child: const Icon(Icons.broken_image, color: Colors.grey),
                );
              },
            ),
            // 传输中遮罩
            if (isTransferring)
              Positioned.fill(
                child: Container(
                  color: Colors.black.withValues(alpha: 0.4),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const CupertinoActivityIndicator(radius: 14, color: Colors.white),
                      const SizedBox(height: 8),
                      Text(
                        '${(msg.progress * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                      ),
                      // 取消按钮：发送端始终显示；接收端仅在非自动接收时显示
                      if (msg.isMe || !_autoReceive) ...[
                        const SizedBox(height: 6),
                        GestureDetector(
                          onTap: () => _cancelTransfer(msg),
                          child: Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color: Colors.redAccent.withValues(alpha: 0.3),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.close, size: 14, color: Colors.white),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            // 失败遮罩
            if (isFailed)
              Positioned.fill(
                child: Container(
                  color: Colors.red.withValues(alpha: 0.15),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.error_outline, color: Colors.redAccent, size: 32),
                      const SizedBox(height: 6),
                      Text(
                        msg.content,
                        style: const TextStyle(color: Colors.redAccent, fontSize: 11),
                        textAlign: TextAlign.center,
                      ),
                      // 发送端显示重试按钮
                      if (msg.isMe) ...[
                        const SizedBox(height: 6),
                        GestureDetector(
                          onTap: () {
                            if (msg.filePath != null) {
                              _sendFileFromPath(msg.filePath!, msg.fileName ?? 'image', isImage: true);
                            }
                          },
                          child: Text(
                            '发送失败，点击重试',
                            style: TextStyle(fontSize: 11, color: Colors.red.shade400, decoration: TextDecoration.underline),
                          ),
                        ),
                      ],
                      // 接收端：点击请求对方重新发送（仅非自动接收时）
                      if (!msg.isMe && !_autoReceive) ...[
                        const SizedBox(height: 6),
                        GestureDetector(
                          onTap: () {
                            widget.msgService.sendFileAccept(
                              targetIp: widget.id,
                              originalFileName: msg.fileName ?? '',
                            );
                            final index = chatData.indexWhere((m) => m.id == msg.id);
                            if (index != -1) {
                              setState(() {
                                chatData[index] = msg.copyWith(
                                  content: '📥 等待对方重新发送: ${msg.fileName ?? ''}',
                                  transferState: TransferState.pending,
                                );
                              });
                              _cacheService.updateMessage(widget.id, msg.id, chatData[index]);
                            }
                          },
                          child: Text(
                            '点击继续接收',
                            style: TextStyle(fontSize: 11, color: Colors.blue.shade400, decoration: TextDecoration.underline),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 文字/文件气泡
  Widget _buildContentBubble(
    ChatMessage msg,
    bool isFile,
    bool isTransferring,
    bool isFailed,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: msg.isMe
            ? (isFile ? const Color(0xFFE3EDF7) : const Color(0xFF95EC69))
            : Colors.white,
        borderRadius: BorderRadius.circular(5),
        border: isFile
            ? Border.all(
                color: isFailed ? Colors.red.shade200 : Colors.black12,
                width: 0.5)
            : null,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 2,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 文件图标 + 文件名
          if (isFile) ...[
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _getFileIcon(msg.fileName ?? ''),
                  size: 28,
                  color: isFailed ? Colors.red.shade300 : const Color(0xFF5B9CF5),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        msg.fileName ?? '未知文件',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Colors.black87,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (msg.fileSize != null)
                        Text(
                          msg.fileSize!,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[500],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
          ],

          // 消息内容文本
          if (msg.content.isNotEmpty && !isFile)
            SelectableText(
              msg.content,
              style: const TextStyle(
                fontSize: 16,
                color: Colors.black87,
                height: 1.4,
              ),
            )
          else if (isFile)
            Text(
              msg.content,
              style: TextStyle(
                fontSize: 12,
                color: isFailed ? Colors.red : Colors.grey[600],
                height: 1.3,
              ),
            ),

          // 进度条（传输中时显示）+ 取消按钮
          // 取消按钮：发送端始终显示；接收端仅在非自动接收时显示
          if (isTransferring) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: msg.progress > 0 ? msg.progress : null,
                minHeight: 4,
                backgroundColor: Colors.grey[200],
                valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF07C160)),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${(msg.progress * 100).toStringAsFixed(0)}%',
                  style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                ),
                if (msg.isMe || !_autoReceive) ...[
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => _cancelTransfer(msg),
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: Colors.redAccent.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.close,
                        size: 12,
                        color: Colors.redAccent,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],

          // 失败重试按钮
          if (isFailed && msg.isMe) ...[
            const SizedBox(height: 6),
            GestureDetector(
              onTap: () {
                // 重新发送
                if (msg.filePath != null) {
                  _sendFileFromPath(msg.filePath!, msg.fileName ?? 'file',
                      isImage: msg.type == MessageType.image);
                }
              },
              child: Text(
                '发送失败，点击重试',
                style: TextStyle(fontSize: 12, color: Colors.red.shade400),
              ),
            ),
          ],
          // 接收端失败/已拒绝：点击请求对方重新发送（仅非自动接收时有效）
          if (isFailed && !msg.isMe && !_autoReceive) ...[
            const SizedBox(height: 6),
            GestureDetector(
              onTap: () {
                // 发送 file_accept 请求对方重新发送
                widget.msgService.sendFileAccept(
                  targetIp: widget.id,
                  originalFileName: msg.fileName ?? '',
                );
                // 更新本地消息为"等待对方重新发送"
                final index = chatData.indexWhere((m) => m.id == msg.id);
                if (index != -1) {
                  setState(() {
                    chatData[index] = msg.copyWith(
                      content: '📥 等待对方重新发送: ${msg.fileName ?? ''}',
                      transferState: TransferState.pending,
                    );
                  });
                  _cacheService.updateMessage(widget.id, msg.id, chatData[index]);
                }
              },
              child: Text(
                '点击继续接收',
                style: TextStyle(fontSize: 12, color: Colors.blue.shade400, decoration: TextDecoration.underline),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 根据文件扩展名返回图标
  IconData _getFileIcon(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    switch (ext) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'doc':
      case 'docx':
        return Icons.description;
      case 'xls':
      case 'xlsx':
        return Icons.table_chart;
      case 'ppt':
      case 'pptx':
        return Icons.slideshow;
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'bmp':
      case 'webp':
        return Icons.image;
      case 'mp4':
      case 'avi':
      case 'mov':
      case 'mkv':
        return Icons.videocam;
      case 'mp3':
      case 'wav':
      case 'flac':
      case 'aac':
        return Icons.audiotrack;
      case 'zip':
      case 'rar':
      case '7z':
      case 'tar':
      case 'gz':
        return Icons.folder_zip;
      case 'apk':
        return Icons.android;
      case 'txt':
        return Icons.article;
      default:
        return Icons.insert_drive_file;
    }
  }

  Widget _buildInputBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      color: const Color(0xFFF7F7F7),
      child: SafeArea(
        child: Row(
          children: [
            IconButton(
              icon: Icon(
                _isVoice ? Icons.keyboard : Icons.mic,
                color: Colors.black87,
              ),
              onPressed: () {
                setState(() {
                  _isVoice = !_isVoice;
                  if (_isVoice) {
                    _focusNode.unfocus();
                    _isMore = false;
                    _emojiState = false;
                  } else {
                    _focusNode.requestFocus();
                  }
                });
              },
            ),
            Expanded(
              child: _isVoice
                  ? Container(
                      height: 40,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.black12, width: 0.5),
                      ),
                      child: const Text(
                        '按住 说话',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.black54,
                        ),
                      ),
                    )
                  : Container(
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: TextField(
                        controller: _textController,
                        focusNode: _focusNode,
                        maxLines: null,
                        textInputAction: TextInputAction.send,
                        onSubmitted: _handleSubmittedData,
                        onChanged: (v) => setState(() {}),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 9,
                          ),
                        ),
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
            ),
            IconButton(
              icon: Icon(
                _emojiState ? Icons.keyboard : Icons.insert_emoticon,
                color: Colors.black87,
              ),
              onPressed: onTapEmoji,
            ),
            _textController.text.isNotEmpty
                ? Padding(
                    padding: const EdgeInsets.only(right: 8.0, left: 4.0),
                    child: SizedBox(
                      height: 34,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF07C160),
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        onPressed: () =>
                            _handleSubmittedData(_textController.text),
                        child:
                            const Text('发送', style: TextStyle(fontSize: 14)),
                      ),
                    ),
                  )
                : IconButton(
                    icon: const Icon(
                      Icons.add_circle_outline,
                      color: Colors.black87,
                    ),
                    onPressed: onTapMore,
                  ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmojiWidget() {
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 45.0,
        mainAxisSpacing: 15.0,
        crossAxisSpacing: 15.0,
        childAspectRatio: 1.0,
      ),
      padding: const EdgeInsets.all(15.0),
      itemCount: _emojiList.length,
      itemBuilder: (BuildContext context, int index) {
        final String mockEmoji = _emojiList[index];
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => insertText(mockEmoji),
          child: Center(
            child: Text(mockEmoji, style: const TextStyle(fontSize: 26)),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _msgSubscription?.cancel();
    _progressSubscription?.cancel();
    _newTaskSubscription?.cancel();
    _transferService.dispose();
    _textController.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 构建精选常用 emoji 列表，跳过 Unicode 未分配的空白区间
  static List<String> _buildEmojiList() {
    // 表情/笑脸 (U+1F600–U+1F64F)
    final smileys = List.generate(80, (i) => String.fromCharCode(0x1F600 + i));
    // 杂项符号与象形文字 (U+1F300–U+1F5FF 中的 emoji 部分)
    final misc = List.generate(768, (i) => String.fromCharCode(0x1F300 + i));
    // 交通与地图 (U+1F680–U+1F6FF)
    final transport = List.generate(128, (i) => String.fromCharCode(0x1F680 + i));
    // 补充符号 (U+1F900–U+1F9FF)
    final supplement = List.generate(256, (i) => String.fromCharCode(0x1F900 + i));
    // 常用手势/人物 (U+270A–U+27BF 和 U+1F440–U+1F450)
    final gestures = <String>[
      '\u{1F44D}', '\u{1F44E}', '\u{1F44F}', '\u{1F44A}',
      '\u{270A}', '\u{270B}', '\u{270C}', '\u{1F44C}',
      '\u{1F450}', '\u{1F932}',
    ];

    final all = <String>[
      ...smileys,
      ...misc,
      ...transport,
      ...supplement,
      ...gestures,
    ];

    // 过滤掉已知不可渲染的字符（某些码点没有字形）
    final valid = <String>[];
    for (final ch in all) {
      final cp = ch.runes.first;
      // 跳过未分配的 Unicode 区域
      if (cp >= 0x1F4D0 && cp <= 0x1F4FF) continue; // 部分未分配
      if (cp >= 0x1F550 && cp <= 0x1F5FF) continue; // 部分未分配
      if (cp >= 0x1F650 && cp <= 0x1F67F) continue; // 装饰性符号（很多平台不显示）
      if (cp >= 0x1F6D5 && cp <= 0x1F6FF) continue; // 部分未分配
      if (cp >= 0x1F780 && cp <= 0x1F7FF) continue; // 几何形状扩展
      if (cp >= 0x1F800 && cp <= 0x1F8FF) continue; // 补充箭头-C
      if (cp >= 0x1FA00 && cp <= 0x1FA6F) continue; // 国际象棋
      if (cp >= 0x1FA70 && cp <= 0x1FAFF) continue; // 扩展-A 中的非 emoji
      valid.add(ch);
    }

    return valid;
  }
}
