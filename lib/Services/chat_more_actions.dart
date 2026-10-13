// E1：更多面板动作映射。从 Chat/chat_more_page.dart 抽出，可单测。
// 图标组装/回调绑定留宿主；此处仅做名称→动作键与未实现文案。

/// 动作键：file/photo/camera/folder/unknown。
String moreActionKey(String name) {
  switch (name) {
    case '文件':
      return 'file';
    case '照片':
      return 'photo';
    case '拍摄':
      return 'camera';
    case '文件夹':
      return 'folder';
    default:
      return 'unknown';
  }
}

/// 是否需要回退提示（回调为空时走未实现 toast）。
bool needsNotImplementedFallback({
  required String key,
  required bool hasPhoto,
  required bool hasCamera,
  required bool hasFolder,
}) {
  switch (key) {
    case 'photo':
      return !hasPhoto;
    case 'camera':
      return !hasCamera;
    case 'folder':
      return !hasFolder;
    case 'file':
      return false;
    default:
      return true;
  }
}

/// 未实现提示文案。
String moreNotImplementedText(String name) => '$name 功能开发中';

/// 更多面板四项名称表（顺序即展示顺序）。
List<String> moreItemNames() => const ['照片', '拍摄', '文件', '文件夹'];

/// 更多面板自适应布局：竖屏 4 列横屏 6 列；边距/尺寸 clamp 收敛。
({int crossAxisCount, double horizontalPadding, double iconBoxSize,
    double iconSize, double fontSize, double spacing})
    moreGridLayout({required double screenWidth, required bool isLandscape}) {
  final crossAxisCount = isLandscape ? 6 : 4;
  final horizontalPadding = screenWidth * 0.04;
  final availableWidth = screenWidth - horizontalPadding * 2 - 16;
  final itemWidth = availableWidth / crossAxisCount;
  final iconBoxSize = (itemWidth * 0.55).clamp(44.0, 60.0);
  final iconSize = (iconBoxSize * 0.45).clamp(22.0, 30.0);
  final fontSize = (iconBoxSize * 0.2).clamp(11.0, 13.0);
  final spacing = iconBoxSize * 0.3;
  return (
    crossAxisCount: crossAxisCount,
    horizontalPadding: horizontalPadding,
    iconBoxSize: iconBoxSize,
    iconSize: iconSize,
    fontSize: fontSize,
    spacing: spacing,
  );
}

/// 面板主轴长度：图标 + 间距 + 文字高度。
double moreMainAxisExtent(double iconBoxSize, double spacing) =>
    iconBoxSize + spacing + 20;

/// 图标下间距。
double moreIconGap(double boxSize) => boxSize * 0.15;
