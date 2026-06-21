import 'package:flutter/material.dart';

class ChatMorePage extends StatelessWidget {
  final String id;
  final VoidCallback onFileSelected; // 文件选择
  final VoidCallback? onPickImage; // 相册选择图片
  final VoidCallback? onTakePhoto; // 拍照

  const ChatMorePage({super.key, 
    required this.id,
    required this.onFileSelected,
    this.onPickImage,
    this.onTakePhoto,
  });

  final List<Map<String, dynamic>> items = const [
    {"name": "照片", "icon": Icons.photo, "color": 0xFF07C160},
    {"name": "拍摄", "icon": Icons.camera_alt, "color": 0xFFFA9C3B},
    {"name": "文件", "icon": Icons.folder_open, "color": 0xFF5B9CF5},
    {"name": "位置", "icon": Icons.location_on, "color": 0xFFE06060},
  ];

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    // 自适应列数：竖屏 4 列，横屏 6 列
    final crossAxisCount = isLandscape ? 6 : 4;

    // 动态计算间距和大小，避免 Android 溢出
    final horizontalPadding = screenWidth * 0.04;
    final availableWidth =
        screenWidth - horizontalPadding * 2 - 16; // 减去左右 padding 和 scroll 空间
    final itemWidth = availableWidth / crossAxisCount;

    // 图标容器大小：取 itemWidth 的 55%，但不超过 60
    final iconBoxSize = (itemWidth * 0.55).clamp(44.0, 60.0);
    // 图标大小
    final iconSize = (iconBoxSize * 0.45).clamp(22.0, 30.0);
    // 字体大小
    final fontSize = (iconBoxSize * 0.2).clamp(11.0, 13.0);
    // 间距
    final spacing = iconBoxSize * 0.3;

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: spacing,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              mainAxisSpacing: spacing,
              crossAxisSpacing: spacing,
              mainAxisExtent: iconBoxSize + spacing + 20, // 图标 + 间距 + 文字高度
            ),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              return _buildItem(
                context,
                item,
                iconBoxSize,
                iconSize,
                fontSize,
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildItem(
    BuildContext context,
    Map<String, dynamic> item,
    double boxSize,
    double iconSize,
    double fontSize,
  ) {
    return GestureDetector(
      onTap: () => _onItemTap(context, item['name'] as String),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: boxSize,
            height: boxSize,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              item['icon'] as IconData,
              size: iconSize,
              color: Color(item['color'] as int),
            ),
          ),
          SizedBox(height: boxSize * 0.15),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              item['name'] as String,
              style: TextStyle(
                fontSize: fontSize,
                color: Colors.grey[700],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  void _onItemTap(BuildContext context, String name) {
    switch (name) {
      case '文件':
        onFileSelected();
        break;
      case '照片':
        if (onPickImage != null) {
          onPickImage!();
        } else {
          _showNotImplemented(context, name);
        }
        break;
      case '拍摄':
        if (onTakePhoto != null) {
          onTakePhoto!();
        } else {
          _showNotImplemented(context, name);
        }
        break;
      case '位置':
        _showNotImplemented(context, name);
        break;
      default:
        _showNotImplemented(context, name);
    }
  }

  void _showNotImplemented(BuildContext context, String name) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$name 功能开发中'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
