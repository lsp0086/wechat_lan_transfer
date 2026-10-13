import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../Services/message_cache_service.dart';
import '../Services/toast_utils.dart';
import '../Services/chat_info_texts.dart';

class ChatInfoPage extends StatefulWidget {
  final String id; // 局域网目标 IP
  final String name; // 目标设备昵称
  final MessageCacheService cacheService;
  final bool initialAutoReceive; // 初始的自动接收状态
  final bool initialIsBlocked; // 初始的黑名单状态

  const ChatInfoPage({
    super.key,
    required this.id,
    required this.name,
    required this.cacheService,
    required this.initialAutoReceive,
    required this.initialIsBlocked,
  });

  @override
  State<ChatInfoPage> createState() => _ChatInfoPageState();
}

class _ChatInfoPageState extends State<ChatInfoPage> {
  bool isTop = false;
  bool isBlocked = false;
  late bool autoReceive; // 从父页面传入初始值；缺省 false（P0-S7，父页面透传已持久化值，未配置时为 false）

  @override
  void initState() {
    super.initState();
    autoReceive = widget.initialAutoReceive;
    isBlocked = widget.initialIsBlocked;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDF0F3),
      appBar: AppBar(
        // E1：标题抽至 chat_info_texts.infoTitle。
        title: Text(infoTitle()),
        backgroundColor: const Color(0xFFF3F3F3),
        elevation: 0.5,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black87),
          onPressed: () => Navigator.pop(context, (autoReceive: autoReceive, isBlocked: isBlocked, chatHistoryCleared: false)),
        ),
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            // 设备基本状态卡片
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(20),
              margin: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  const CircleAvatar(
                    radius: 30,
                    child: Icon(Icons.devices, size: 30),
                  ),
                  const SizedBox(width: 15),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.name,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        // E1：IP 行抽至 chat_info_texts.infoIpLine。
                        infoIpLine(widget.id),
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // 传输设置
            // E1：三行标签抽至 chat_info_texts。
            _buildSettingRow(infoTopLabel(), isTop, (v) => setState(() => isTop = v)),
            _buildSettingRow(
              infoBlockLabel(),
              isBlocked,
              (v) => setState(() => isBlocked = v),
            ),
            _buildSettingRow(
              infoAutoRecvLabel(),
              autoReceive,
              (v) => setState(() => autoReceive = v),
            ),

            const SizedBox(height: 12),

            // 清除聊天记录（替代原"断开与该设备的连接"）
            Container(
              color: Colors.white,
              child: ListTile(
                // E1：清除行抽至 chat_info_texts.infoClearLabel。
                title: Text(
                  infoClearLabel(),
                  style: TextStyle(fontSize: 16, color: Colors.redAccent),
                ),
                onTap: () => _clearChatHistory(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _clearChatHistory() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        // E1：确认框文案抽至 chat_info_texts。
        title: Text(infoClearTitle()),
        content: Text(infoClearContent(widget.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(infoCancelText()),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: Text(infoConfirmClearText()),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await widget.cacheService.clearMessagesForDevice(widget.id);
        if (mounted) {
          showCenterToast(context, infoClearedText(widget.name));
          Navigator.pop(context, (
            autoReceive: autoReceive,
            isBlocked: isBlocked,
            chatHistoryCleared: true,
          ));
        }
      } catch (e) {
        if (mounted) {
          // E1：失败文案抽至 chat_info_texts.infoClearFailText。
          showCenterToast(context, infoClearFailText(e));
        }
      }
    }
  }

  Widget _buildSettingRow(String title, bool value, Function(bool) onChanged) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: const TextStyle(fontSize: 16)),
          CupertinoSwitch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
