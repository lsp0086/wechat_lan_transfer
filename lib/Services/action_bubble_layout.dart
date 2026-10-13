// E1：动作气泡布局纯函数。从 ChatPage._showActionBubble 抽出，可单测。
// 输入标签/目标矩形/屏幕尺寸与安全区，输出气泡几何；Overlay 挂载留宿主。

import 'transfer_limits.dart';

/// 气泡布局结果。
class ActionBubbleLayout {
  final double popupWidth;
  final double left;
  final double arrowX;
  final double top;
  final bool showBelow;
  final bool arrowOnTop;
  const ActionBubbleLayout({
    required this.popupWidth,
    required this.left,
    required this.arrowX,
    required this.top,
    required this.showBelow,
    required this.arrowOnTop,
  });
}

/// 按标签长度估算气泡宽度并 clamp 到屏幕。
/// E1：系数/上下限抽至 transfer_limits（经参数默认收敛，签名保持兼容）。
double actionBubbleWidth({
  required List<String> labels,
  required double screenWidth,
  double perChar = kBubblePerChar,
  double perLabel = kBubblePerLabel,
  double gap = kBubbleGap,
  double minW = kBubbleMinW,
  double edge = kBubbleEdge,
}) {
  var contentWidth = 0.0;
  for (final label in labels) {
    contentWidth += label.length * perChar + perLabel;
  }
  if (labels.length > 1) contentWidth += (labels.length - 1) * gap;
  return contentWidth.clamp(minW, screenWidth - edge);
}

/// 气泡几何常量（_showActionBubble/_ActionBubblePainter 共用）。
const double kActionBubbleH = 40.0;
const double kActionBubbleArrowH = 7.0;
const double kActionBubbleArrowW = 11.0;
const double kActionBubbleRadius = 10.0;
const double kActionBubbleGap = 4.0;
const double kActionBubbleEdge = 12.0;

/// 气泡主体矩形顶：箭头在上则下移箭头高，否则贴顶（纯函数可单测）。
double bubbleRectTop({required bool arrowOnTop, required double arrowH}) =>
    arrowOnTop ? arrowH : 0.0;

// E1：气泡底边距收敛（箭头在上则贴边，否则留箭头高）。
double bubbleEdgeBottom({required bool arrowOnTop, required double arrowH}) =>
    arrowOnTop ? 0 : arrowH;

/// 气泡主体高：总高减箭头高。
double bubbleBodyHeight({required double height, required double arrowH}) =>
    height - arrowH;

/// 箭头三角三点：上箭头尖端在顶，下箭头尖端在底（纯几何可单测）。
List<({double x, double y})> arrowTriangle({
  required bool arrowOnTop,
  required double centerX,
  required double arrowW,
  required double arrowH,
  required double height,
}) {
  if (arrowOnTop) {
    return [
      (x: centerX, y: 0),
      (x: centerX - arrowW / 2, y: arrowH),
      (x: centerX + arrowW / 2, y: arrowH),
    ];
  }
  final baseY = height - arrowH;
  return [
    (x: centerX - arrowW / 2, y: baseY),
    (x: centerX + arrowW / 2, y: baseY),
    (x: centerX, y: height),
  ];
}

/// 气泡重绘门控：箭头位置/方向任一变化才重绘。
bool shouldRepaintBubble({
  required double arrowX,
  required bool arrowOnTop,
  required double oldArrowX,
  required bool oldArrowOnTop,
}) =>
    arrowX != oldArrowX || arrowOnTop != oldArrowOnTop;

// E1：重复 clamp 收敛（computeActionBubbleLayout 已 clamp，此处仅收敛调用点重复）。
double clampBubbleTop({
  required double top,
  required double safeTop,
  required double screenH,
  required double totalH,
  required double safeBottom,
}) =>
    top.clamp(safeTop, screenH - totalH - safeBottom);

// E1：动作分隔线门控（首项无分隔线）。
bool shouldShowActionDivider(int index) => index > 0;

// E1：RenderBox 有效性门控（纯判定，box 获取留宿主）。
bool isInvalidRenderBox({required bool isNull, required bool hasSize}) =>
    isNull || !hasSize;

/// 完整布局：水平居中 clamp 12px，优先放下方，箭头位置 clamp。
ActionBubbleLayout computeActionBubbleLayout({
  required List<String> labels,
  required double targetLeft,
  required double targetTop,
  required double targetRight,
  required double targetBottom,
  required double targetCenterX,
  required double screenWidth,
  required double screenHeight,
  required double safeTop,
  required double safeBottom,
  double bubbleH = kActionBubbleH,
  double arrowH = kActionBubbleArrowH,
  double gap = kActionBubbleGap,
}) {
  final totalHeight = bubbleH + arrowH;
  final popupWidth = actionBubbleWidth(
    labels: labels,
    screenWidth: screenWidth,
  );
  var left = targetCenterX - popupWidth / 2;
  if (left < kBubbleClampEdge) left = kBubbleClampEdge;
  if (left + popupWidth > screenWidth - kBubbleClampEdge) {
    left = screenWidth - popupWidth - kBubbleClampEdge;
  }
  final arrowX =
      (targetCenterX - left).clamp(kBubbleClampEdge, popupWidth - kBubbleClampEdge);
  final showBelow =
      (targetBottom + totalHeight + gap + safeBottom) < screenHeight;
  final top =
      showBelow ? targetBottom + gap : targetTop - totalHeight - gap;
  return ActionBubbleLayout(
    popupWidth: popupWidth,
    left: left,
    arrowX: arrowX,
    top: top.clamp(safeTop, screenHeight - totalHeight - safeBottom),
    showBelow: showBelow,
    arrowOnTop: showBelow,
  );
}
