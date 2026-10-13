import 'dart:async';
import 'package:flutter/material.dart';
import '../Model/chat_model.dart';
import '../Services/audio_service.dart';
import '../Services/audio_bubble_meta.dart';

/// 语音气泡组件：类似微信的声波图 + 时长 + 点击播放
/// - 显示声波图动画
/// - 显示录音时长
/// - 点击播放/暂停
/// - 未读红点（接收方首次）
class AudioBubble extends StatefulWidget {
  final ChatMessage msg;
  final AudioService audioService;

  const AudioBubble({super.key, required this.msg, required this.audioService});

  @override
  State<AudioBubble> createState() => _AudioBubbleState();
}

class _AudioBubbleState extends State<AudioBubble>
    with SingleTickerProviderStateMixin {
  List<double>? _bars;
  bool _isPlaying = false;
  int _playProgressMs = 0;
  late AnimationController _pulseController;
  StreamSubscription<PlaybackState>? _playbackSub;
  StreamSubscription<Duration>? _positionSub;

  @override
  void initState() {
    super.initState();
    _bars = _parseOrGenerateWaveform(widget.msg);

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    // P1-8：订阅必须在 dispose 取消，避免泄漏/串音
    _playbackSub = widget.audioService.playbackStream.listen((state) {
      if (!mounted) return;
      // E1：路径抽至 audio_bubble_meta.audioPlayPath。
      final ourPath = audioPlayPath(
        filePath: widget.msg.filePath,
        imagePath: widget.msg.imagePath,
      );
      final currentPlaying = widget.audioService.currentPlayingPath;

      // E1：切歌停播门控抽至 audio_bubble_meta.shouldStopForOtherPath。
      if (shouldStopForOtherPath(
        currentPlaying: currentPlaying,
        ourPath: ourPath,
        isPlaying: _isPlaying,
      )) {
        _stopProgress();
        setState(() {
          _isPlaying = false;
          _playProgressMs = 0;
        });
        return;
      }
      if (currentPlaying != ourPath) {
        if (_isPlaying) {
          _stopProgress();
          setState(() {
            _isPlaying = false;
            _playProgressMs = 0;
          });
        }
        return;
      }

      setState(() {
        _isPlaying = state == PlaybackState.playing;
      });
      if (state == PlaybackState.playing) {
        _listenPosition();
      } else if (state == PlaybackState.stopped) {
        _stopProgress();
        setState(() {
          _playProgressMs = 0;
        });
      }
    });
  }

  void _listenPosition() {
    _positionSub?.cancel();
    _positionSub = widget.audioService.positionStream.listen((pos) {
      if (!mounted) return;
      // E1：路径抽至 audio_bubble_meta.audioPlayPath。
      final ourPath = audioPlayPath(
        filePath: widget.msg.filePath,
        imagePath: widget.msg.imagePath,
      );
      if (widget.audioService.currentPlayingPath != ourPath) return;
      setState(() {
        _playProgressMs = pos.inMilliseconds;
      });
    });
  }

  void _stopProgress() {
    _positionSub?.cancel();
    _positionSub = null;
  }

  @override
  void dispose() {
    _playbackSub?.cancel();
    _stopProgress();
    _pulseController.dispose();
    super.dispose();
  }

  /// 解析或从 msgId 确定性生成声波图振幅数据
  /// E1：解析/回退抽至 audio_bubble_meta.parseOrNeutralWaveform。
  List<double> _parseOrGenerateWaveform(ChatMessage msg) =>
      parseOrNeutralWaveform(msg.waveformData);

  /// 格式化时长
  /// E1：抽至 audio_bubble_meta.formatAudioBubbleDuration。
  String _formatDuration(int ms) => formatAudioBubbleDuration(ms);

  @override
  Widget build(BuildContext context) {
    final isMe = widget.msg.isMe;
    final duration = widget.msg.durationMs;
    final durationText = _formatDuration(duration);

    // 气泡宽度根据时长动态变化（E1：抽至 audio_bubble_meta.calcAudioBubbleWidth）。
    final bubbleWidth = calcAudioBubbleWidth(durationMs: duration);

    return GestureDetector(
      onTap: () => _onTap(),
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: bubbleWidth,
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: isMe ? const Color(0xFF95EC69) : Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(5),
            topRight: const Radius.circular(5),
            bottomLeft: isMe ? const Radius.circular(5) : Radius.zero,
            bottomRight: isMe ? Radius.zero : const Radius.circular(5),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 2,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Row(
          children: [
            // 播放/暂停图标
            SizedBox(
              width: 28,
              child: Icon(
                _isPlaying ? Icons.pause : Icons.play_arrow,
                size: 20,
                color: isMe ? const Color(0xFF1AAD19) : const Color(0xFF576B95),
              ),
            ),

            // 声波图
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: CustomPaint(
                  size: Size.infinite,
                  painter: _WaveformPainter(
                    bars: _bars!,
                    color: isMe
                        ? const Color(0xFF1AAD19)
                        : const Color(0xFF576B95),
                    isPlaying: _isPlaying,
                    // E1：抽至 audio_bubble_meta.playProgressOf。
                    playProgress: playProgressOf(
                      progressMs: _playProgressMs,
                      durationMs: widget.msg.durationMs,
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(width: 4),

            // 时长文字
            Text(
              durationText,
              style: TextStyle(
                fontSize: 12,
                color: Colors.black54,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onTap() async {
    // E1：路径抽至 audio_bubble_meta.audioPlayPath。
    final filePath = audioPlayPath(
      filePath: widget.msg.filePath,
      imagePath: widget.msg.imagePath,
    );
    if (filePath == null || filePath.isEmpty) return;

    if (_isPlaying) {
      await widget.audioService.stop();
      _stopProgress();
      setState(() => _playProgressMs = 0);
    } else {
      final ok = await widget.audioService.play(filePath);
      if (ok) {
        setState(() => _isPlaying = true);
        _listenPosition();
      }
    }
  }
}

/// 声波图绘制器
class _WaveformPainter extends CustomPainter {
  final List<double> bars;
  final Color color;
  final bool isPlaying;
  final double playProgress; // 0.0 ~ 1.0

  _WaveformPainter({
    required this.bars,
    required this.color,
    required this.isPlaying,
    required this.playProgress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;

    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round;

    final playedPaint = Paint()
      ..color = color.withValues(alpha: 0.35)
      ..strokeCap = StrokeCap.round;

    // E1：几何/已播/线宽抽至 audio_bubble_meta（纯函数可单测）。
    final playedCount = playedBarCount(total: bars.length, progress: playProgress);

    for (int i = 0; i < bars.length; i++) {
      final g = waveBarLayout(
        index: i,
        count: bars.length,
        amplitude: bars[i],
        totalWidth: size.width,
        totalHeight: size.height,
      );

      final barPaint =
          isBarPlayed(index: i, playedCount: playedCount) ? playedPaint : paint;
      barPaint.strokeWidth = clampBarStroke(g.width);

      canvas.drawLine(
        Offset(g.x + g.width / 2, g.y),
        Offset(g.x + g.width / 2, g.y + g.height),
        barPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) {
    return oldDelegate.isPlaying != isPlaying ||
        oldDelegate.playProgress != playProgress ||
        oldDelegate.bars != bars;
  }
}
