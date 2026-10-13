// U3：传输保活桥。有传输任务时拉起 Android 前台 Service（wake lock 保活），
// 任务空闲时停止并释锁。非 Android 平台为 no-op；通道不可用（旧版本/测试）静默忽略。
// 对标 LocalSend v1.18 android run in background + release wake lock。

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

class TransferKeepalive {
  TransferKeepalive._();
  static const MethodChannel _channel = MethodChannel(
    'wechat_lan_transfer/keepalive',
  );
  static bool _active = false;
  // U3-遗留：通知权限已请求过（每会话一次，拒绝不再重复弹）。
  static bool _notifAsked = false;

  /// 传输开始（活跃任务 0→1）：拉起前台 Service 并持有 wake lock。
  static Future<void> start({String text = '传输进行中'}) async {
    if (!Platform.isAndroid || _active) return;
    _active = true;
    // U3-遗留：Android 13+ 前台 Service 通知需 POST_NOTIFICATIONS 运行时授权；
    // 首次传输时请求一次，拒绝/永久拒绝不再重复弹（Service 仍可运行，仅无通知）。
    if (!_notifAsked) {
      _notifAsked = true;
      try {
        final status = await Permission.notification.request();
        debugPrint('[Keepalive] U3 通知权限: $status');
      } catch (e) {
        debugPrint('[Keepalive] U3 通知权限请求失败（忽略）: $e');
      }
    }
    try {
      await _channel.invokeMethod('start', {'text': text});
      debugPrint('[Keepalive] U3 前台 Service 已拉起: $text');
    } catch (e) {
      debugPrint('[Keepalive] U3 前台 Service 拉起失败（忽略）: $e');
    }
  }

  /// 进度文本更新（通知栏文案；节流由调用方负责）。
  static Future<void> update(String text) async {
    if (!Platform.isAndroid || !_active) return;
    try {
      await _channel.invokeMethod('update', {'text': text});
    } catch (_) {}
  }

  /// 全部任务结束（活跃任务归零）：停止前台 Service 并释锁。
  static Future<void> stop() async {
    if (!Platform.isAndroid || !_active) return;
    _active = false;
    try {
      await _channel.invokeMethod('stop');
      debugPrint('[Keepalive] U3 前台 Service 已停止（释锁）');
    } catch (e) {
      debugPrint('[Keepalive] U3 前台 Service 停止失败（忽略）: $e');
    }
  }
}
