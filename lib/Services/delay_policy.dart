// E1：延时策略薄委托。从 ChatPage _fileAcceptTimeout 别名与 Future.delayed
// 常量构造抽出，可单测。定时器创建（Timer/Timer.periodic）留宿主，只抽 Duration 构造。

import 'dart:async';

import 'record_policy.dart' show kRecordTickMs;
import 'send_dispatch.dart' show kPanelSwitchMs, kScrollAnimMs;
import 'transfer_limits.dart';

/// 发送队列间隔（直调 transfer_limits.kTextSendGapMs）。
Duration ackGap() => Duration(milliseconds: kTextSendGapMs);

/// 面板切换防抖（直调 send_dispatch.kPanelSwitchMs）。
Duration panelDebounce() => Duration(milliseconds: kPanelSwitchMs);

/// 滚动动画时长（直调 send_dispatch.kScrollAnimMs）。
Duration scrollAnim() => Duration(milliseconds: kScrollAnimMs);

/// 动作气泡自动隐藏（直调 transfer_limits.kActionBubbleSec）。
Duration bubbleHide() => Duration(seconds: kActionBubbleSec);

/// 录音 tick 步长（直调 record_policy.kRecordTickMs）。
Duration recordTick() => Duration(milliseconds: kRecordTickMs);

/// 通用间隔等待薄委托（默认调 Future.delayed，语义不变）。
Future<void> gapDelay(Duration d) => Future.delayed(d);
