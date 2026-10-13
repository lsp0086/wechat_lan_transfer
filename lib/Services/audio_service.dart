import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:wechat_lan_transfer/Services/file_size_format.dart' as fsf;

/// 录音 / 播放服务
/// - 使用 record 包进行跨平台录音（Android/iOS/Windows/macOS/Linux）
/// - 使用 audioplayers 包进行跨平台音频播放
class AudioService {
  static final AudioService _instance = AudioService._();
  factory AudioService() => _instance;
  AudioService._();

  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  // U7：时长探测复用单例，避免每次 durationOf 都 new/dispose 一个播放器。
  AudioPlayer? _probe;

  // 播放状态
  final StreamController<PlaybackState> _playbackController =
      StreamController<PlaybackState>.broadcast();
  Stream<PlaybackState> get playbackStream => _playbackController.stream;

  String? _currentPlayingPath;
  PlaybackState _currentState = PlaybackState.stopped;
  StreamSubscription<void>? _playerCompleteSub;

  /// 获取当前播放器状态
  PlaybackState get currentState => _currentState;

  /// 当前正在播放（或暂停）的文件路径
  String? get currentPlayingPath => _currentPlayingPath;

  // ===================== 录音 =====================

  /// 检查麦克风权限
  Future<bool> hasPermission() async {
    return await _recorder.hasPermission();
  }

  /// 开始录音，返回 false 表示录音失败
  Future<String?> startRecording() async {
    try {
      if (await _recorder.isRecording()) {
        debugPrint('[AudioService] 录音器已在运行中');
        return null;
      }

      final hasPerm = await _recorder.hasPermission();
      if (!hasPerm) {
        debugPrint('[AudioService] 没有麦克风权限');
        return null;
      }

      // 创建录音文件路径
      final dir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final filePath = '${dir.path}/voice_$timestamp.m4a';

      // 配置录音参数：单声道 AAC，16kHz 采样率，低码率适合语音
      const config = RecordConfig(
        encoder: AudioEncoder.aacLc,
        numChannels: 1,
        sampleRate: 16000,
        bitRate: 32000,
      );

      await _recorder.start(config, path: filePath);
      debugPrint('[AudioService] 开始录音: $filePath');
      return filePath;
    } catch (e) {
      debugPrint('[AudioService] 开始录音失败: $e');
      return null;
    }
  }

  /// 获取录音振幅流（P1-7：真实 PCM 振幅，归一化 0.0~1.0）
  Stream<double> get amplitudeStream =>
      _recorder.onAmplitudeChanged(const Duration(milliseconds: 80)).map((amp) {
        // Amplitude.current 为 dBFS，常见范围约 -60~0
        return ((amp.current + 60) / 60).clamp(0.08, 1.0);
      });

  /// P1-8：真实播放进度
  Stream<Duration> get positionStream => _player.onPositionChanged;

  /// 停止录音。P1-7：优先使用调用方计时的真实时长，不再用 fileSize/4000 覆盖。
  Future<RecordResult?> stopRecording({required int durationMs}) async {
    try {
      final path = await _recorder.stop();
      if (path == null || path.isEmpty) {
        debugPrint('[AudioService] 停止录音失败：路径为空');
        return null;
      }

      final file = File(path);
      if (!await file.exists()) {
        debugPrint('[AudioService] 录音文件不存在: $path');
        return null;
      }

      final fileSize = await file.length();
      final actualDurationMs = durationMs > 0 ? durationMs : 0;
      debugPrint(
        '[AudioService] 录音结束: $path, 大小=${_formatSize(fileSize)}, 时长=${actualDurationMs}ms',
      );
      return RecordResult(
        path: path,
        durationMs: actualDurationMs,
        fileSize: fileSize,
      );
    } catch (e) {
      debugPrint('[AudioService] 停止录音失败: $e');
      return null;
    }
  }

  /// 取消录音（放弃录音文件）
  Future<void> cancelRecording() async {
    try {
      final path = await _recorder.stop();
      if (path != null && path.isNotEmpty) {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
          debugPrint('[AudioService] 已取消录音并删除文件: $path');
        }
      }
    } catch (e) {
      debugPrint('[AudioService] 取消录音失败: $e');
    }
  }

  // ===================== 播放 =====================

  /// 播放音频文件
  Future<bool> play(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        debugPrint('[AudioService] 音频文件不存在: $filePath');
        return false;
      }

      // 如果正在播放同一个文件，则暂停/继续
      if (_currentPlayingPath == filePath &&
          _currentState == PlaybackState.playing) {
        await _player.pause();
        _updateState(PlaybackState.paused);
        return true;
      }
      if (_currentPlayingPath == filePath &&
          _currentState == PlaybackState.paused) {
        await _player.resume();
        _updateState(PlaybackState.playing);
        return true;
      }

      // 停止之前的播放
      await stop();

      _currentPlayingPath = filePath;
      await _player.play(DeviceFileSource(filePath));
      _updateState(PlaybackState.playing);

      // 监听播放完成（取消旧订阅，防止内存泄漏）
      _playerCompleteSub?.cancel();
      _playerCompleteSub = _player.onPlayerComplete.listen((_) {
        if (_currentPlayingPath == filePath) {
          _updateState(PlaybackState.stopped);
        }
      });

      return true;
    } catch (e) {
      debugPrint('[AudioService] 播放失败: $e');
      return false;
    }
  }

  /// P1-7 / U7：读取音频文件真实时长（旧端未透传元数据时补全）。
  /// 复用探测播放器，3 秒超时，失败返回 0 不阻塞消息展示。
  Future<int> durationOf(String filePath) async {
    try {
      final probe = _probe ??= AudioPlayer();
      await probe
          .setSource(DeviceFileSource(filePath))
          .timeout(const Duration(seconds: 3));
      final duration = await probe
          .getDuration()
          .timeout(const Duration(seconds: 3));
      return duration?.inMilliseconds ?? 0;
    } catch (e) {
      debugPrint('[AudioService] 读取音频时长失败: $e');
      return 0;
    }
  }

  /// 停止播放
  Future<void> stop() async {
    try {
      await _player.stop();
      _playerCompleteSub?.cancel();
      _playerCompleteSub = null;
      _updateState(PlaybackState.stopped);
      _currentPlayingPath = null;
    } catch (e) {
      debugPrint('[AudioService] 停止播放失败: $e');
    }
  }

  void _updateState(PlaybackState state) {
    _currentState = state;
    _playbackController.add(state);
  }

  String _formatSize(int bytes) => fsf.formatFileSize(bytes);

  /// 释放资源
  void dispose() {
    _playerCompleteSub?.cancel();
    _recorder.dispose();
    _player.dispose();
    _probe?.dispose();
    _probe = null;
    _playbackController.close();
  }
}

/// 录音结果
class RecordResult {
  final String path;
  final int durationMs;
  final int fileSize;

  RecordResult({
    required this.path,
    required this.durationMs,
    required this.fileSize,
  });
}

/// 播放状态
enum PlaybackState { stopped, playing, paused }
