// E1：音频展示格式。从 ChatPage 抽出的纯函数，可单测。
// 录音时长展示 + 波形降采样编码（降采样复用 ProtocolCodec.downsampleWaveform）。

import 'dart:convert';

import 'package:wechat_lan_transfer/Services/protocol_codec.dart';

import 'transfer_limits.dart';

/// 录音时长格式化：<60s 显示 `12″`，否则 `m′ss″`。
String formatRecordDuration(int durationMs) {
  final seconds = durationMs / 1000;
  if (seconds < 60) return '${seconds.toStringAsFixed(0)}\u2033';
  final m = (seconds / 60).floor();
  final s = (seconds % 60).floor();
  return '$m\u2032${s.toString().padLeft(2, '0')}\u2033';
}

/// 振幅降采样为固定柱数 JSON（空输入返回默认 0.15 占位）。
/// E1：抽至 transfer_limits.kWaveformBars。
String encodeWaveformFromAmps(List<double> amps, {int bars = kWaveformBars}) {
  return jsonEncode(ProtocolCodec.downsampleWaveform(amps, bars: bars));
}

// E1：波形有效判定（有采样才绘制）。
bool hasWaveform(List l) => l.isNotEmpty;

/// 录制波形单柱几何（E1：从 _RecordingWavePainter.paint 抽出，可单测）。
/// 与 Canvas 解耦：返回柱中心 x、顶 y 与柱高。
({double x, double y, double height}) waveBarGeometry({
  required int index,
  required int count,
  required double amplitude,
  required double width,
  required double height,
}) {
  if (count <= 0) return (x: 0, y: height / 2, height: 0);
  final stepX = width / count;
  final x = index * stepX + stepX / 2;
  final barHeight = amplitude * height;
  final y = (height - barHeight) / 2;
  return (x: x, y: y, height: barHeight);
}
