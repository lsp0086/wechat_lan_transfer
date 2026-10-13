// E1：对端身份纯函数。从 ChatPage._targetIp/_peerFingerprint/_handleIncomingMessage
// 抽出，可单测。行为不变：peerIp 有效优先，否则回退 id；id 为 64hex 指纹才用。

import 'transfer_limits.dart';

String resolveTargetIp({required String peerIp, required String id}) {
  if (peerIp.isNotEmpty && peerIp != kInvalidIp) return peerIp;
  return id;
}

/// id 为 64 位 hex 指纹时返回小写，否则 null（旧端无加密）。
String? resolvePeerFingerprint(String id) {
  if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(id)) return id.toLowerCase();
  return null;
}

/// 设备 id 是否有效（非空且非 0.0.0.0 历史 bug）。
/// E1：抽至 transfer_limits.kInvalidIp。
bool isDeviceIdValid(String id) => id.isNotEmpty && id != kInvalidIp;

/// 是否应忽略入站消息：id 有效且发送方与三者全不等才忽略。
bool shouldIgnoreIncoming({
  required String deviceId,
  required String peerIp,
  required String targetIp,
  required String senderIp,
}) {
  if (!isDeviceIdValid(deviceId)) return false;
  return senderIp != deviceId &&
      senderIp != peerIp &&
      senderIp != targetIp;
}

// E1：缓存迁移判定收敛（身份键与当前 IP 不一致才迁）。
bool needsCacheMigrate(String key, String ip) => key != ip;
