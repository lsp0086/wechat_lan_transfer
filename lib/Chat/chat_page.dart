import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import '../Model/chat_model.dart';
import '../Services/file_transfer_service.dart';
import '../Services/message_cache_service.dart';
import 'chat_more_page.dart';
import 'chat_info_page.dart';

class ChatPage extends StatefulWidget {
  final String title;
  final String id;

  ChatPage({required this.id, required this.title});

  @override
  _ChatPageState createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  List<ChatMessage> chatData = [];
  List<String> _emojiList = [];
  bool _isVoice = false;
  bool _isMore = false;
  double keyboardHeight = 270.0;
  bool _emojiState = false;

  final TextEditingController _textController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  // 服务层
  final FileTransferService _transferService = FileTransferService();
  final MessageCacheService _cacheService = MessageCacheService();
  final ImagePicker _imagePicker = ImagePicker();

  StreamSubscription<FileTransferTask>? _progressSubscription;
  StreamSubscription<FileTransferTask>? _newTaskSubscription;

  @override
  void initState() {
    super.initState();
    _emojiList = List.generate(
      1212,
      (index) => String.fromCharCode(0x1F601 + index),
    );

    _focusNode.addListener(() {
      if (_focusNode.hasFocus) {
        setState(() {
          _emojiState = false;
          _isMore = false;
        });
      }
    });

    _initChat();
  }

  Future<void> _initChat() async {
    // 1. 启动文件接收服务器
    await _transferService.startServer();

    // 2. 监听新接收文件
    _newTaskSubscription = _transferService.newTaskStream.listen((task) {
      _onFileReceived(task);
    });

    // 3. 监听传输进度更新
    _progressSubscription = _transferService.progressStream.listen((task) {
      _updateTransferProgress(task);
    });

    // 4. 从缓存加载聊天记录
    final cachedMessages = await _cacheService.loadMessages(widget.id);
    if (cachedMessages.isNotEmpty) {
      setState(() {
        chatData = cachedMessages;
      });
    } else {
      // 首次进入，插入系统消息
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
  }

  // ========== 文件接收回调 ==========
  void _onFileReceived(FileTransferTask task) {
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

  // ========== 更新传输进度 ==========
  void _updateTransferProgress(FileTransferTask task) {
    final index = chatData.indexWhere((m) => m.taskId == task.id);
    if (index == -1) return;

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

  // ========== 图片选择器（相册） ==========
  Future<void> _pickImageFromGallery() async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 90,
      );

      if (image != null) {
        // 先显示图片消息
        final imgMsg = ChatMessage(
          id: 'img_${DateTime.now().millisecondsSinceEpoch}',
          senderId: 'me',
          content: '📷 图片',
          type: MessageType.image,
          timestamp: DateTime.now(),
          isMe: true,
          fileName: image.name,
          filePath: image.path,
          imagePath: image.path,
          transferState: TransferState.completed,
        );

        setState(() {
          chatData.add(imgMsg);
        });
        _cacheService.appendMessage(widget.id, imgMsg);

        // 然后发送图片文件
        _sendFileFromPath(image.path, image.name);
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
        final imgMsg = ChatMessage(
          id: 'cam_${DateTime.now().millisecondsSinceEpoch}',
          senderId: 'me',
          content: '📸 拍摄的照片',
          type: MessageType.image,
          timestamp: DateTime.now(),
          isMe: true,
          fileName: photo.name,
          filePath: photo.path,
          imagePath: photo.path,
          transferState: TransferState.completed,
        );

        setState(() {
          chatData.add(imgMsg);
        });
        _cacheService.appendMessage(widget.id, imgMsg);

        _sendFileFromPath(photo.path, photo.name);
      }
    } catch (e) {
      debugPrint("拍照失败: $e");
    }
  }

  // ========== 发送文件（通用） ==========
  Future<void> _sendFileFromPath(String filePath, String fileName) async {
    try {
      await _transferService.sendFile(
        filePath: filePath,
        targetIp: widget.id,
        customFileName: fileName,
      );
      // 进度更新由 _progressSubscription 统一处理
    } catch (e) {
      debugPrint("发送文件失败: $e");
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
  }

  void onTapMore() {
    setState(() {
      _isVoice = false;
      if (_focusNode.hasFocus) {
        _focusNode.unfocus();
        _isMore = true;
      } else {
        _isMore = !_isMore;
      }
      _emojiState = false;
    });
  }

  void onTapEmoji() {
    setState(() {
      _isVoice = false;
      if (_isMore) {
        _emojiState = true;
        _isMore = false;
      } else {
        _emojiState = !_emojiState;
      }

      if (_emojiState) {
        _focusNode.unfocus();
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
    if (keyboardHeight == 270.0 &&
        MediaQuery.of(context).viewInsets.bottom != 0) {
      keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    }

    return Scaffold(
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
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      ChatInfoPage(id: widget.id, name: widget.title),
                ),
              );
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
                setState(() {
                  _isMore = false;
                  _emojiState = false;
                });
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
            visible: _emojiState && !_focusNode.hasFocus,
            child: Container(
              height: keyboardHeight,
              color: const Color(0xFFF6F6F6),
              child: _buildEmojiWidget(),
            ),
          ),
          Visibility(
            visible: _isMore && !_focusNode.hasFocus,
            child: Container(
              height: keyboardHeight,
              color: const Color(0xFFF6F6F6),
              child: ChatMorePage(
                id: widget.id,
                keyboardHeight: keyboardHeight,
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

  /// 图片气泡
  Widget _buildImageBubble(ChatMessage msg) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.55,
          maxHeight: 220,
        ),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.black12, width: 0.5),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Image.file(
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
            Text(
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

          // 进度条（传输中时显示）
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
            const SizedBox(height: 2),
            Text(
              '${(msg.progress * 100).toStringAsFixed(0)}%',
              style: TextStyle(fontSize: 11, color: Colors.grey[500]),
            ),
          ],

          // 失败重试按钮
          if (isFailed) ...[
            const SizedBox(height: 6),
            GestureDetector(
              onTap: () {
                // 重新发送
                if (msg.filePath != null) {
                  _sendFileFromPath(msg.filePath!, msg.fileName ?? 'file');
                }
              },
              child: Text(
                '发送失败，点击重试',
                style: TextStyle(fontSize: 12, color: Colors.red.shade400),
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
    _progressSubscription?.cancel();
    _newTaskSubscription?.cancel();
    _transferService.dispose();
    _textController.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}
