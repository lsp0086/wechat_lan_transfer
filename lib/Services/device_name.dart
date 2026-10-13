// E1：设备名探测。从 ChatListPage._fetchRealDeviceName 抽出（无 UI 依赖）。

import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

/// 动态获取真实设备名称（降级链：硬件名 → 平台缺省名）。
Future<String> detectDeviceName() async {
  final deviceInfo = DeviceInfoPlugin();
  try {
    if (Platform.isAndroid) {
      final androidInfo = await deviceInfo.androidInfo;
      return "${androidInfo.manufacturer} ${androidInfo.model}";
    } else if (Platform.isIOS) {
      final iosInfo = await deviceInfo.iosInfo;
      return iosInfo.name;
    } else if (Platform.isWindows) {
      final windowsInfo = await deviceInfo.windowsInfo;
      return windowsInfo.computerName;
    } else if (Platform.isMacOS) {
      final macosInfo = await deviceInfo.macOsInfo;
      return macosInfo.computerName;
    } else if (Platform.isLinux) {
      final linuxInfo = await deviceInfo.linuxInfo;
      return linuxInfo.name;
    }
  } catch (e) {
    debugPrint("读取硬件设备名失败，降级处理: $e");
  }
  return Platform.isAndroid
      ? "Android 手机"
      : (Platform.isWindows ? "Windows 电脑" : "局域网设备");
}
