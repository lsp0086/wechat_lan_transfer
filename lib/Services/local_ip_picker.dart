// E1：本机主 IP 优选。从 ChatListPage._initLanDiscovery 抽出的纯函数，可单测。
// wifiIP（NetworkInfo）优先且必须私有；否则 192.168.* 优先，否则首个 v4；
// 无有效 IP 返回 null（调用方置"未知IP"并跳过绑定）。

import 'transfer_limits.dart';

/// 从候选 v4 列表选主 IP（null = 无有效局域网 IP）。
String? pickLocalIp({required String? wifiIp, required List<String> v4Ips}) {
  if (isUsableWifiIp(wifiIp)) {
    return wifiIp;
  }
  final nonEmpty = v4Ips.where((ip) => ip.isNotEmpty).toList();
  if (nonEmpty.isEmpty) return null;
  for (final ip in nonEmpty) {
    if (ip.startsWith('192.168.')) return ip;
  }
  return nonEmpty.first;
}

// E1：Wi-Fi IP 可用判定收敛（非空/非 0.0.0.0/私有 v4，复用本文件私有判定）。
bool isUsableWifiIp(String? ip) {
  if (ip == null || ip.isEmpty || ip == '0.0.0.0' || ip == kInvalidIp) {
    return false;
  }
  return _isPrivateV4(ip);
}

bool _isPrivateV4(String ip) {
  final parts = ip.split('.');
  if (parts.length != 4) return false;
  final a = int.tryParse(parts[0]);
  final b = int.tryParse(parts[1]);
  if (a == null || b == null) return false;
  if (a == 10) return true;
  if (a == 172 && b >= 16 && b <= 31) return true;
  if (a == 192 && b == 168) return true;
  return false;
}
