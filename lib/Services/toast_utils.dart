import 'dart:async';
import 'package:flutter/material.dart';

import 'transfer_limits.dart';

/// 屏幕居中显示一个圆角气泡提示，3 秒后自动消失。
/// 可在任意有 BuildContext 的地方调用。
/// E1：时长抽至 transfer_limits.kToastSec。
void showCenterToast(BuildContext context, String message) {
  final overlay = Overlay.of(context);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xCC333333),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            message,
            style: const TextStyle(color: Colors.white, fontSize: 15),
          ),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  Future.delayed(const Duration(seconds: kToastSec), () {
    entry.remove();
  });
}
