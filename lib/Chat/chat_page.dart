import 'package:flutter/material.dart';
import '../Model/chat_model.dart';
import 'chat_more_page.dart';
import 'chat_info_page.dart';

class ChatPage extends StatefulWidget {
  final String title; // 对方设备名称，例如 "我的三星 S24" 或 "Windows 电脑"
  final String id; // 对方设备的局域网 IP 地址

  ChatPage({required this.id, required this.title});

  @override
  _ChatPageState createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  // 核心改动：使用我们自己纯净的本地消息列表，摆脱 V2TimMessage 依赖
  List<ChatMessage> chatData = [];
  List<String> _emojiList = [];
  bool _isVoice = false;
  bool _isMore = false;
  double keyboardHeight = 270.0;
  bool _emojiState = false;

  final TextEditingController _textController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _emojiList = List.generate(
      1212,
      (index) => String.fromCharCode(0x1F601 + index),
    );
    // 监听输入框焦点，当键盘弹起时自动隐藏表情面板和“+”号面板
    _focusNode.addListener(() {
      if (_focusNode.hasFocus) {
        setState(() {
          _emojiState = false;
          _isMore = false;
        });
      }
    });

    // 初始化一条默认的局域网连接成功提示
    chatData = [
      ChatMessage(
        id: 'init_msg',
        senderId: widget.id,
        content: '局域网传输通道已建立。正在与设备 [${widget.title}] 连接...',
        type: MessageType.text,
        timestamp: DateTime.now(),
        isMe: false,
      ),
    ];
  }

  // 往输入框光标处插入文本（供假表情面板使用）
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

  // 点击发送按钮触发的方法
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

    // 修复原项目方法不存在的崩溃，改用 Flutter 官方标准的 addPostFrameCallback
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });

    // TODO: 后面在这里接入局域网 HTTP/Socket 发送逻辑：
    // LanTransportService.sendText(widget.id, text);
  }

  // 点击底部“+”号面板控制
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

  // 点击表情按钮控制
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

  @override
  Widget build(BuildContext context) {
    // 动态捕捉软键盘高度，保证面板展开与软键盘等高
    if (keyboardHeight == 270.0 &&
        MediaQuery.of(context).viewInsets.bottom != 0) {
      keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    }

    return Scaffold(
      backgroundColor: const Color(0xFFEDF0F3), // 纯正微信聊天背景色
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
          // 消息列表展示区
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

          // 底部控制栏
          _buildInputBar(),

          // 表情面板区域
          Visibility(
            visible: _emojiState && !_focusNode.hasFocus,
            child: Container(
              height: keyboardHeight,
              color: const Color(0xFFF6F6F6),
              child: _buildEmojiWidget(),
            ),
          ),

          // “+”号更多功能面板区域（照片、文件传输等）
          Visibility(
            visible: _isMore && !_focusNode.hasFocus,
            child: Container(
              height: keyboardHeight,
              color: const Color(0xFFF6F6F6),
              child: ChatMorePage(
                id: widget.id,
                keyboardHeight: keyboardHeight,
                onFileSelected: (fileName, filePath) {
                  // 用户在更多面板选择文件后的回调接收
                  setState(() {
                    chatData.add(
                      ChatMessage(
                        id: DateTime.now().toString(),
                        senderId: 'me',
                        content: '📄 发送局域网文件：$fileName\n路径: $filePath',
                        type: MessageType.file,
                        fileName: fileName,
                        timestamp: DateTime.now(),
                        isMe: true,
                      ),
                    );
                  });
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 精准高仿微信聊天气泡
  Widget _buildChatBubble(ChatMessage msg) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: msg.isMe
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!msg.isMe)
            CircleAvatar(
              backgroundColor: Colors.blueGrey,
              child: Text(
                widget.title.isNotEmpty ? widget.title.substring(0, 1) : "机",
                style: const TextStyle(color: Colors.white),
              ),
            ),
          const SizedBox(width: 8),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: msg.isMe
                    ? const Color(0xFF95EC69)
                    : Colors.white, // 微信绿 vs 纯白
                borderRadius: BorderRadius.circular(5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 2,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              child: Text(
                msg.content,
                style: const TextStyle(
                  fontSize: 16,
                  color: Colors.black87,
                  height: 1.4,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (msg.isMe)
            const CircleAvatar(
              backgroundColor: Colors.teal,
              child: Text('我', style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
    );
  }

  // 纯正高仿微信底部多功能全适配输入栏
  Widget _buildInputBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      color: const Color(0xFFF7F7F7),
      child: SafeArea(
        child: Row(
          children: [
            // 语音按钮切换（音符图标已被正宗麦克风替换！）
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

            // 输入区域控制（语音长条与键盘输入动态切换）
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

            // 表情按钮
            IconButton(
              icon: Icon(
                _emojiState ? Icons.keyboard : Icons.insert_emoticon,
                color: Colors.black87,
              ),
              onPressed: onTapEmoji,
            ),

            // “+”号面板按钮与“发送”文本按钮动态切换
            _textController.text.isNotEmpty
                ? Padding(
                    padding: const EdgeInsets.only(right: 8.0, left: 4.0),
                    child: SizedBox(
                      height: 34,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF07C160), // 微信绿发送键
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        onPressed: () =>
                            _handleSubmittedData(_textController.text),
                        child: const Text('发送', style: TextStyle(fontSize: 14)),
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

  // 本地原生简易表情面板（脱水解耦，防资源文件找不到报错）
  Widget _buildEmojiWidget() {
    return GridView.builder(
      // 使用 MaxCrossAxisExtent
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 45.0, // 每个 Emoji 盒子的最大宽度/高度
        mainAxisSpacing: 15.0, // 行间距
        crossAxisSpacing: 15.0, // 列间距
        childAspectRatio: 1.0, // 宽高比固定为 1:1 正方形
      ),
      padding: const EdgeInsets.all(15.0),
      itemCount: _emojiList.length,
      itemBuilder: (BuildContext context, int index) {
        final String mockEmoji = _emojiList[index];
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => insertText(mockEmoji),
          // 使用 Center 包裹，确保 Emoji 在固定大小的格子居中
          child: Center(
            child: Text(mockEmoji, style: const TextStyle(fontSize: 26)),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _textController.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}
