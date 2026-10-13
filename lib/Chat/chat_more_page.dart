import 'package:flutter/material.dart';
import '../Services/toast_utils.dart';
import '../Services/chat_more_actions.dart';

class ChatMorePage extends StatelessWidget {
  final String id;
  final VoidCallback onFileSelected; // 文件选择
  final VoidCallback? onPickImage; // 相册选择图片
  final VoidCallback? onTakePhoto; // 拍照
  final VoidCallback? onFolderSelected; // 文件夹选择

  const ChatMorePage({super.key, 
    required this.id,
    required this.onFileSelected,
    this.onPickImage,
    this.onTakePhoto,
    this.onFolderSelected,
  });

  final List<Map<String, dynamic>> items = const [
    {"name": "照片",   "icon": Icons.photo,               "color": 0xFF07C160},
    {"name": "拍摄",   "icon": Icons.camera_alt,           "color": 0xFFFA9C3B},
    {"name": "文件",   "icon": Icons.insert_drive_file,    "color": 0xFF5B9CF5},
    {"name": "文件夹", "icon": Icons.folder,               "color": 0xFFE06060},
  ];

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    // 自适应列数：竖屏 4 列，横屏 6 列
    // E1：边距/尺寸计算抽至 chat_more_actions.moreGridLayout。
    final layout = moreGridLayout(
      screenWidth: screenWidth,
      isLandscape: isLandscape,
    );
    final crossAxisCount = layout.crossAxisCount;

    // 动态计算间距和大小，避免 Android 溢出
    // E1：边距/尺寸经 moreGridLayout 统一计算，此处仅取用。
    final horizontalPadding = layout.horizontalPadding;

    // 图标容器大小：取 itemWidth 的 55%，但不超过 60
    final iconBoxSize = layout.iconBoxSize;
    // 图标大小
    final iconSize = layout.iconSize;
    // 字体大小
    final fontSize = layout.fontSize;
    // 间距
    final spacing = layout.spacing;

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
              // E1：主轴长度抽至 chat_more_actions.moreMainAxisExtent。
              mainAxisExtent: moreMainAxisExtent(iconBoxSize, spacing),
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
          SizedBox(height: moreIconGap(boxSize)),
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
    // E1：名称→动作键与回退门控抽至 chat_more_actions。
    final key = moreActionKey(name);
    final needFallback = needsNotImplementedFallback(
      key: key,
      hasPhoto: onPickImage != null,
      hasCamera: onTakePhoto != null,
      hasFolder: onFolderSelected != null,
    );
    if (needFallback && key != 'file') {
      _showNotImplemented(context, name);
      return;
    }
    switch (key) {
      case 'file':
        onFileSelected();
        break;
      case 'photo':
        onPickImage!();
        break;
      case 'camera':
        onTakePhoto!();
        break;
      case 'folder':
        onFolderSelected!();
        break;
      default:
        _showNotImplemented(context, name);
    }
  }

  void _showNotImplemented(BuildContext context, String name) {
    // E1：文案抽至 chat_more_actions.moreNotImplementedText。
    showCenterToast(context, moreNotImplementedText(name));
  }
}
