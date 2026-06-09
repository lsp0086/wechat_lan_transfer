import 'package:flutter/material.dart';

class ChatMorePage extends StatelessWidget {
  final String id;
  final double keyboardHeight;
  final Function(String fileName, String filePath) onFileSelected; // 回调给主界面渲染气泡

  ChatMorePage({
    required this.id,
    required this.keyboardHeight,
    required this.onFileSelected,
  });

  // 模拟微信“+”面板的卡片数据
  final List<Map<String, dynamic>> items = [
    {"name": "照片", "icon": Icons.photo},
    {"name": "拍摄", "icon": Icons.camera_alt},
    {"name": "文件", "icon": Icons.folder_open},
    {"name": "位置", "icon": Icons.location_on},
  ];

  void _onItemPressed(BuildContext context, String name) async {
    if (name == '文件' || name == '照片') {
      // 💡 局域网传输核心逻辑建议：
      // 在你的新项目 pubspec.yaml 引入 file_picker 库后：
      // FilePickerResult? result = await FilePicker.platform.pickFiles();
      // if (result != null) {
      //    String name = result.files.single.name;
      //    String? path = result.files.single.path;
      //    onFileSelected(name, path ?? '');
      // }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('点击了：$name，请在项目引入 file_picker 获取真实本地路径')),
      );
      onFileSelected("测试传输文件.zip", "/mock/path/file.zip");
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$name 功能开发中')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: EdgeInsets.all(20),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 20,
        crossAxisSpacing: 20,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return GestureDetector(
          onTap: () => _onItemPressed(context, item['name']),
          child: Column(
            children: [
              Container(
                padding: EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  item['icon'] as IconData,
                  size: 28,
                  color: Colors.black87,
                ),
              ),
              SizedBox(height: 8),
              Text(
                item['name'] as String,
                style: TextStyle(fontSize: 12, color: Colors.grey[700]),
              ),
            ],
          ),
        );
      },
    );
  }
}
