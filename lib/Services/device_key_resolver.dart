// E1：P0-7 身份键解析。从 ChatListPage 抽出的纯函数，可单测。
// deviceId（TLS 指纹）优先，旧端回退 IP；黑名单同时匹配 IP 与身份键。

import 'transfer_limits.dart';

/// 从 UDP payload 提取对端身份：deviceId 优先，否则 tlsFp，否则空串。
String deviceIdFromPayload(Map<String, dynamic>? payload) {
  final did = (payload?['deviceId'] as String?)?.isNotEmpty == true
      ? payload!['deviceId'] as String
      : (payload?['tlsFp'] as String? ?? '');
  return did;
}

/// 发送前把身份键解析为当前路由 IP；查不到时原样返回（legacy：键即 IP）。
String resolveDeviceIp({required String deviceKey, String? currentIp}) =>
    currentIp ?? deviceKey;

/// 黑名单命中：同时匹配 IP 与身份键，兼容 legacy 条目。
bool isBlockedEntry(Set<String> blocked, String ip, String? deviceId) =>
    blocked.contains(ip) ||
    (deviceId != null && deviceId.isNotEmpty && blocked.contains(deviceId));

/// E1：广播身份解析（从 ChatListPage._handleIncomingBroadcast 抽出的纯函数，可单测）。
/// rawId 缺省/0.0.0.0 时回退 UDP 来源 IP，再回退 payload.senderIp；
/// 身份键：deviceId（持久指纹）优先，旧端无 deviceId 回退解析出的 IP。
/// 无法确定发送方 IP（三者均空/0.0.0.0）时返回 null，调用方丢弃。
/// E1：哨兵抽至 transfer_limits.kInvalidIp。
({String ip, String deviceKey})? resolveBroadcastIdentity(
  Map<String, dynamic> deviceData,
  String senderIP,
) {
  final rawId = deviceData['id'] as String? ?? '';
  final payloadSenderIp = deviceData['senderIp'] as String? ?? '';
  var ip = rawId;
  if (ip.isEmpty || ip == kInvalidIp) ip = senderIP;
  if (ip.isEmpty || ip == kInvalidIp) ip = payloadSenderIp;
  if (ip.isEmpty || ip == kInvalidIp) return null;
  final did = deviceIdFromPayload(deviceData);
  final deviceKey = did.isNotEmpty ? did : ip;
  return (ip: ip, deviceKey: deviceKey);
}
