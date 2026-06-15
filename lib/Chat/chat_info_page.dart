import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

class ChatInfoPage extends StatefulWidget {
  final String id; // 局域网目标 IP
  final String name; // 目标设备昵称

  const ChatInfoPage({super.key, required this.id, required this.name});

  @override
  _ChatInfoPageState createState() => _ChatInfoPageState();
}

class _ChatInfoPageState extends State<ChatInfoPage> {
  bool isTop = false;
  bool isBlocked = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDF0F3),
      appBar: AppBar(
        title: Text('设备详情'),
        backgroundColor: const Color(0xFFF3F3F3),
        elevation: 0.5,
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            // 设备基本状态卡片
            Container(
              color: Colors.white,
              padding: EdgeInsets.all(20),
              margin: EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 30,
                    child: Icon(Icons.devices, size: 30),
                  ),
                  SizedBox(width: 15),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.name,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SizedBox(height: 5),
                      Text(
                        '局域网IP: ${widget.id}',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // 局域网传输控制项
            _buildSettingRow('置顶该设备', isTop, (v) => setState(() => isTop = v)),
            _buildSettingRow(
              '加入传输黑名单',
              isBlocked,
              (v) => setState(() => isBlocked = v),
            ),

            Container(
              width: double.infinity,
              margin: EdgeInsets.all(20),
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  padding: EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: () {
                  // 断开局域网 Socket 连接的代码
                  Navigator.pop(context);
                },
                child: Text(
                  '断开与该设备的连接',
                  style: TextStyle(color: Colors.white, fontSize: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingRow(String title, bool value, Function(bool) onChanged) {
    return Container(
      color: Colors.white,
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: TextStyle(fontSize: 16)),
          CupertinoSwitch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
