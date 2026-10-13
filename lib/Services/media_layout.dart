// E1：图片尺寸/解压/路径纯函数。从 ChatPage 几何与 ZIP 安全残留抽出，可单测。
import 'dart:ui';

import 'transfer_limits.dart';

/// 是否支持图片压缩（flutter_image_compress 仅 Android/iOS/macOS）。
bool isThumbCompressSupported({
  required bool isAndroid,
  required bool isIOS,
  required bool isMacOS,
}) =>
    isAndroid || isIOS || isMacOS;

/// 缩略图压缩参数三元组（quality/minW/minH）。
({int quality, int minWidth, int minHeight}) thumbCompressParams() => (
      quality: kThumbQuality,
      minWidth: kThumbMinWidth,
      minHeight: kThumbMinHeight,
    );

/// 图片显示尺寸：按比例缩放， clamp 最大宽高与最小值。
/// E1：上下限抽至 transfer_limits.kImage*（默认参数保持签名兼容）。
Size calcImageDisplaySize({
  required Size? imageSize,
  required double screenWidth,
  double maxHeight = kImageMaxHeight,
  double minWidth = kImageMinWidth,
  double minHeight = kImageMinHeight,
}) {
  final maxWidth = screenWidth * kImageWidthRatio;
  if (imageSize == null) return Size(maxWidth * 0.75, 160);
  final ratio = imageSize.width / imageSize.height;
  var displayWidth = maxWidth;
  var displayHeight = maxWidth / ratio;
  if (displayHeight > maxHeight) {
    displayHeight = maxHeight;
    displayWidth = maxHeight * ratio;
  }
  if (displayWidth < minWidth) displayWidth = minWidth;
  if (displayHeight < minHeight) displayHeight = minHeight;
  return Size(displayWidth, displayHeight);
}

/// 可疑 zip 条目（含 .. 即跳过）。
bool isSuspiciousZipEntry(String name) => name.contains('..');

/// 解压累计超限判定。
bool exceedsExtractLimit({
  required int total,
  required int add,
  required int limit,
}) =>
    total + add > limit;

/// 子路径是否在目标目录内（防穿越）。
bool isPathInside({required String targetAbs, required String childAbs}) =>
    childAbs.startsWith(targetAbs);

/// 序号文件夹名：base (n)。
String nextIndexedFolderName(String base, int counter) => '$base ($counter)';

/// 缩略图生成门控：已完成的图片才生成。
bool shouldGenerateThumbnailAfterComplete({
  required String state,
  required String type,
}) =>
    state == 'completed' && type == 'image';

/// 缩略图目录拼接：docPath/thumbnails（_initChat 三行拼接收敛）。
String buildThumbnailDirPath(String docPath) => '$docPath/thumbnails';

/// 缩略图目录需创建门控：不存在才递归创建。
bool shouldCreateThumbnailDir({required bool exists}) => !exists;

/// zip 本体超限门控：长度 > 上限拒绝解压（保留原文件）。
bool isZipTooLarge({required int length, required int maxBytes}) =>
    length > maxBytes;

/// 解压输出路径：targetDir/safePath（两处手拼收敛，调用方包 pth.join 亦可）。
String joinExtractOutputPath(String targetDir, String safePath) =>
    '$targetDir/$safePath';

/// emoji 网格参数：maxExtent/主副间距/边距/字号（_buildEmojiWidget 魔法数字收敛）。
({double maxExtent, double mainSpacing, double crossSpacing, double padding, double fontSize})
    emojiGridParams() => (
          maxExtent: 45.0,
          mainSpacing: 15.0,
          crossSpacing: 15.0,
          padding: 15.0,
          fontSize: 26.0,
        );

// E1：预览门控收敛（存在才挂 InteractiveViewer）。
bool shouldShowViewer({required bool exists}) => exists;

// E1：预览缩放范围收敛（0.5x~4.0x）。
({double min, double max}) viewerScaleRange() => (min: 0.5, max: 4.0);

// E1：文字/文件内容气泡圆角收敛（原值 5.0）。
double contentBubbleRadius() => 5.0;

// E1：图片气泡圆角收敛（原值 6.0）。
double imageBubbleRadius() => 6.0;

// E1：文件图标尺寸收敛（内容气泡内原值 28.0）。
double fileIconSize() => 28.0;

// E1：气泡旁错误图标尺寸收敛（音频失败原值 22.0）。
double bubbleErrorIconSize() => 22.0;

// E1：输入框底色收敛（Colors.white → ARGB int，宿主包 Color）。
int inputFieldBg() => 0xFFFFFFFF;

// E1：输入栏图标前景收敛（Colors.black87 → ARGB int）。
int inputIconFg() => 0xDD000000;

// E1：输入框圆角收敛（原值 19.0）。
double inputFieldRadius() => 19.0;

// E1：发送按钮尺寸收敛（原值 34.0）。
double sendButtonSize() => 34.0;

// E1：PIN弹窗间距收敛（原值 8.0）。
double pinFieldGapH() => 8.0;
// E1：PIN提示字号收敛（原值 13.0）。
double pinHintFontSize() => 13.0;
