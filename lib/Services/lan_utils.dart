import 'dart:io';

import 'package:flutter/foundation.dart';

/// P2-1：从 chat_list.dart 上帝类抽出的纯网络工具函数（无状态、可单测）

// 利用 Extension 扩展 Platform，优雅地补充 isMobile 属性
extension PlatformMobileExtension on Platform {
  static bool get isMobile => Platform.isAndroid || Platform.isIOS;
}

class LanUtils {
  LanUtils._();

  /// 是否为 64 位十六进制 TLS 指纹（设备身份键）。E1 从 ChatListPage 抽出。
  static bool isFingerprintKey(String s) =>
      RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(s);

  /// 判断是否为私有局域网 IP 地址
  /// 覆盖: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
  /// P1-N2：含 ':' 时按 IPv6 私有地址判定（兼容旧调用方）。
  static bool isPrivateIP(String ip) {
    final normalized = normalizeIp(ip);
    if (normalized.contains(':')) return isPrivateIPv6(normalized);
    try {
      final parts = normalized.split('.');
      if (parts.length != 4) return false;
      final a = int.parse(parts[0]);
      final b = int.parse(parts[1]);
      if (a == 10) return true;
      if (a == 172 && b >= 16 && b <= 31) return true;
      if (a == 192 && b == 168) return true;
      return false;
    } catch (_) {
      return false;
    }
  }

  /// P1-N2：是否为 IPv6 地址（含方括号/scope 归一化后判断）。
  static bool isIPv6(String ip) {
    try {
      final addr = InternetAddress.tryParse(normalizeIp(ip));
      return addr != null && addr.type == InternetAddressType.IPv6;
    } catch (_) {
      return false;
    }
  }

  /// P1-N2：判断是否为私有 IPv6 地址（fe80::/10 link-local，fc00::/7 ULA）。
  static bool isPrivateIPv6(String ip) {
    try {
      final addr = InternetAddress.tryParse(normalizeIp(ip));
      if (addr == null || addr.type != InternetAddressType.IPv6) return false;
      final b = addr.rawAddress;
      if (b.length != 16) return false;
      // fe80::/10
      if (b[0] == 0xFE && (b[1] & 0xC0) == 0x80) return true;
      // fc00::/7
      if ((b[0] & 0xFE) == 0xFC) return true;
      return false;
    } catch (_) {
      return false;
    }
  }

  /// P1-N2：回环地址判断（::1 / 127.0.0.0/8）。
  static bool isLoopback(String ip) {
    try {
      final addr = InternetAddress.tryParse(normalizeIp(ip));
      if (addr == null) return false;
      return addr.isLoopback;
    } catch (_) {
      return false;
    }
  }

  /// P1-N2：IP 归一化——去首尾空格、去方括号、去 scope（%eth0）、IPv6 小写。
  static String normalizeIp(String ip) {
    var s = ip.trim();
    if (s.startsWith('[') && s.endsWith(']') && s.length > 2) {
      s = s.substring(1, s.length - 1);
    }
    final scopeIdx = s.indexOf('%');
    if (scopeIdx != -1 && s.contains(':')) {
      s = s.substring(0, scopeIdx);
    }
    if (s.contains(':')) s = s.toLowerCase();
    return s;
  }

  /// 旧版回退：仅假设 /24，用于 Dart < 3.13 或获取掩码失败时
  static String? legacySubnetBroadcast(String ip) {
    try {
      final parts = ip.split('.');
      if (parts.length != 4) return null;
      // 使用 /24 子网掩码: 广播地址 = 网络部分 + .255
      parts[3] = '255';
      return parts.join('.');
    } catch (_) {
      return null;
    }
  }

  /// E1/U2：解析 "IP:端口" 输入（P1-N1 手动添加设备用，纯函数可单测）。
  /// IPv6 方括号 [fe80::1]:8888；唯一冒号且余数为数字/空 → v4:端口；
  /// 裸 IPv6（多冒号）整体当 IP（修复原实现按最后冒号误拆 `fe80::1`→`fe80:`）；
  /// 归一化后校验可解析。非法返回 null。
  static ({String ip, int port})? parseEndpoint(
    String input, {
    int defaultPort = 8888,
  }) {
    var ip = input;
    var port = defaultPort;
    if (input.startsWith('[')) {
      // IPv6 方括号 [fe80::1]:8888
      final end = input.indexOf(']');
      if (end != -1) {
        ip = input.substring(1, end);
        final rest = input.substring(end + 1);
        if (rest.startsWith(':')) {
          port = int.tryParse(rest.substring(1)) ?? port;
        }
      }
    } else {
      final colon = input.lastIndexOf(':');
      final hasOneColon = colon != -1 && input.indexOf(':') == colon;
      final rest = colon != -1 ? input.substring(colon + 1).trim() : '';
      final restIsPort = rest.isEmpty || int.tryParse(rest) != null;
      if (hasOneColon && restIsPort) {
        ip = input.substring(0, colon).trim();
        port = int.tryParse(rest) ?? port;
      }
      // 其余（裸 IPv6 多冒号 / 无端口 v4）整体当 IP
    }
    ip = normalizeIp(ip);
    if (ip.isEmpty) return null;
    final parsed = InternetAddress.tryParse(ip);
    if (parsed == null) return null;
    return (ip: ip, port: port);
  }
}

/// E1：网卡枚举结果。v4/v6 带接口名（日志用），广播地址按接口掩码或 /24 回退。
class InterfaceScanResult {
  final List<({String name, String ip})> v4Private = [];
  final List<({String name, String ip})> v6Private = [];
  final List<InternetAddress> subnetBroadcasts = [];
}

/// E1/P1-N2：遍历物理网卡（过滤虚拟/VPN 等接口名），收集 v4/v6 私有地址与广播地址。
/// P1-2：Dart 3.13+ InterfaceAddress.broadcast/prefixLength，旧 Dart 回退 /24。
Future<InterfaceScanResult> enumerateInterfaces() async {
  final result = InterfaceScanResult();
  final interfaces = await NetworkInterface.list(
    includeLoopback: false,
    type: InternetAddressType.any,
  );
  for (final interface in interfaces) {
    final name = interface.name.toLowerCase();
    // 过滤虚拟网卡/VPN/隧道等
    if (name.contains('virtual') ||
        name.contains('vbox') ||
        name.contains('vmnet') ||
        name.contains('wsl') ||
        name.contains('vethernet') ||
        name.contains('hyper-v') ||
        name.contains('docker') ||
        name.contains('vpn') ||
        name.contains('tunnel') ||
        name.contains('loopback') ||
        name.contains('pseudo') ||
        name.contains('tap') ||
        name.contains('tun') ||
        name.contains('bridge') ||
        name.contains('bluetooth') ||
        name.contains('usb')) {
      continue;
    }
    for (final addr in interface.addresses) {
      final addressStr = LanUtils.normalizeIp(addr.address);
      // IPv6 仅收集 ULA/link-local，排除回环
      if (addressStr.contains(':')) {
        if (LanUtils.isLoopback(addressStr)) continue;
        if (LanUtils.isPrivateIPv6(addressStr)) {
          result.v6Private.add((name: name, ip: addressStr));
        }
        continue;
      }
      if (addr.type != InternetAddressType.IPv4) continue;
      if (!LanUtils.isPrivateIP(addressStr)) continue;
      result.v4Private.add((name: name, ip: addressStr));
      // P1-2：按接口真实掩码获取广播地址（10/8、172.16/12 大网不再固定 .255）
      try {
        final dynamic addrDyn = addr;
        if (addrDyn is InternetAddress &&
            addrDyn.runtimeType.toString().contains('Interface')) {
          final bcAddr = (addrDyn as dynamic).broadcast as InternetAddress;
          final prefixLen = (addrDyn as dynamic).prefixLength as int;
          if (!result.subnetBroadcasts.any(
            (a) => a.address == bcAddr.address,
          )) {
            result.subnetBroadcasts.add(bcAddr);
            debugPrint('子网广播地址: $addressStr/$prefixLen -> ${bcAddr.address}');
          }
        } else {
          throw UnsupportedError('InterfaceAddress API 不可用');
        }
      } catch (e) {
        debugPrint('获取 $addressStr 广播地址失败（可能旧 Dart 版本）: $e');
        // 回退到 /24 假设（向下兼容）
        final fallback = LanUtils.legacySubnetBroadcast(addressStr);
        if (fallback != null &&
            !result.subnetBroadcasts.any((a) => a.address == fallback)) {
          result.subnetBroadcasts.add(InternetAddress(fallback));
        }
      }
    }
  }
  return result;
}
