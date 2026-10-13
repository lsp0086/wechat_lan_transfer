// E1：语音气泡纯元信息。从 Chat/audio_bubble.dart 抽出，可单测。
// 宽度/时长/波形解析/播放进度均为纯函数，订阅与播放留宿主。

import 'dart:convert';

import 'transfer_limits.dart';

/// 气泡宽度：90~200px，按时长 0~60s 线性。
/// E1：抽至 transfer_limits.kAudioBubble*/kWaveformBars。
double calcAudioBubbleWidth({
  required int durationMs,
  double minWidth = kAudioBubbleMinW,
  double maxWidth = kAudioBubbleMaxW,
  double fullMs = kAudioBubbleFullMs,
}) {
  final t = (durationMs / fullMs).clamp(0.0, 1.0);
  return minWidth + (maxWidth - minWidth) * t;
}

/// 气泡时长文案：<60s 显示 `12"`，否则 `m′ss″`（ceil 秒）。
String formatAudioBubbleDuration(int ms) {
  final seconds = (ms / 1000).ceil();
  if (seconds < 60) return '$seconds"';
  final minutes = seconds ~/ 60;
  final secs = seconds % 60;
  return "$minutes\u2032${secs.toString().padLeft(2, '0')}\u2033";
}

/// 中性静态波形（旧消息无采样时用，不伪造随机振幅）。
List<double> neutralWaveformBars({int bars = kWaveformBars}) =>
    List<double>.filled(bars, 0.25);

/// 解析存储波形 JSON，失败返回 null（调用方回退中性波形）。
List<double>? tryParseWaveformBars(String? waveformData) {
  if (waveformData == null || waveformData.isEmpty) return null;
  try {
    final list = jsonDecode(waveformData) as List<dynamic>;
    return list.map((e) => (e as num).toDouble()).toList();
  } catch (_) {
    return null;
  }
}

/// 解析或回退：有存量用存量，否则中性波形。
List<double> parseOrNeutralWaveform(
  String? waveformData, {
  int bars = kWaveformBars,
}) =>
    tryParseWaveformBars(waveformData) ?? neutralWaveformBars(bars: bars);

/// 播放进度 0~1（duration<=0 按 1000ms 兜底，避免除零）。
/// E1：抽至 transfer_limits.kAudioPlayFallbackMs。
double playProgressOf({
  required int progressMs,
  required int durationMs,
}) {
  final total = durationMs > 0 ? durationMs : kAudioPlayFallbackMs;
  return progressMs / total;
}

/// 播放路径：filePath > imagePath。
String? audioPlayPath({String? filePath, String? imagePath}) =>
    (filePath != null && filePath.isNotEmpty)
        ? filePath
        : ((imagePath != null && imagePath.isNotEmpty) ? imagePath : null);

/// 是否应为切歌停掉当前（当前播放路径与本条不一致且正在播）。
bool shouldStopForOtherPath({
  required String? currentPlaying,
  required String? ourPath,
  required bool isPlaying,
}) =>
    isPlaying && currentPlaying != ourPath;

/// 波形单柱几何（E1：从 _WaveformPainter.paint 抽出，可单测）。
/// 返回柱左 x、柱宽、柱高与顶 y；调用方据此画线。
({double x, double width, double height, double y}) waveBarLayout({
  required int index,
  required int count,
  required double amplitude,
  required double totalWidth,
  required double totalHeight,
  double heightRatio = 0.9,
  double spacingRatio = 0.3,
}) {
  if (count <= 0) return (x: 0, width: 0, height: 0, y: totalHeight / 2);
  final barWidth = totalWidth / count;
  final maxBarHeight = totalHeight * heightRatio;
  final barSpacing = barWidth * spacingRatio;
  final actualBarWidth = barWidth - barSpacing;
  final x = index * barWidth + barSpacing / 2;
  final barHeight = amplitude * maxBarHeight;
  final y = (totalHeight - barHeight) / 2;
  return (x: x, width: actualBarWidth, height: barHeight, y: y);
}

/// 已播柱数：总柱 × 进度四舍五入（纯函数可单测）。
int playedBarCount({required int total, required double progress}) =>
    (total * progress).round();

/// 柱是否已播：序号 < 已播数。
bool isBarPlayed({required int index, required int playedCount}) =>
    index < playedCount;

/// 柱线宽 clamp 1.5~3.5（纯函数可单测）。
double clampBarStroke(double width) => width.clamp(1.5, 3.5);
