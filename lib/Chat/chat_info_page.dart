import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../Services/message_cache_service.dart';

class ChatInfoPage extends StatefulWidget {
  final String id; // 局域网目标 IP
  final String name; // 目标设备昵称
  final MessageCacheService cacheService;
  final bool initialAutoReceive; // 初始的自动接收状态

  const ChatInfoPage({
    super.key,
    required this.id,
    required this.name,
    required this.cacheService,
    required this.initialAutoReceive,
  });

  @override
  _ChatInfoPageState createState() => _ChatInfoPageState();
}

class _ChatInfoPageState extends State<ChatInfoPage> {
  bool isTop = false;
  bool isBlocked = false;
  late bool autoReceive; // 从父页面传入初始值

  @override
  void initState() {
    super.initState();
    autoReceive = widget.initialAutoReceive;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDF0F3),
      appBar: AppBar(
        title: const Text('设备详情'),
        backgroundColor: const Color(0xFFF3F3F3),
        elevation: 0.5,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black87),
          onPressed: () => Navigator.pop(context, autoReceive),
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
                        '局域网IP: ${widget.id}',
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // 传输设置
            _buildSettingRow('置顶该设备', isTop, (v) => setState(() => isTop = v)),
            _buildSettingRow(
              '加入传输黑名单',
              isBlocked,
              (v) => setState(() => isBlocked = v),
            ),
            _buildSettingRow(
              '自动接收文件',
              autoReceive,
              (v) => setState(() => autoReceive = v),
            ),

            const SizedBox(height: 12),

            // 清除聊天记录（替代原"断开与该设备的连接"）
            Container(
              color: Colors.white,
              child: ListTile(
                title: const Text(
                  '清除聊天记录',
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
        title: const Text('清除聊天记录'),
        content: Text('确定要清除与 ${widget.name} 的所有聊天记录吗？\n\n此操作不会删除设备记录，仅清空聊天消息。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('确定清除'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await widget.cacheService.clearMessagesForDevice(widget.id);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('已清除与 ${widget.name} 的聊天记录'),
              duration: const Duration(seconds: 1),
            ),
          );
          Navigator.pop(context, autoReceive);
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('清除失败: $e')),
          );
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
