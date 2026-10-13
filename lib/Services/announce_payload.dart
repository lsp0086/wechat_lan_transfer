// E1：上线宣告载荷。从 ChatListPage._doBroadcast/_sendDirectReply 抽出的纯函数，可单测。
// 广播与单播回包共用：id/senderIp/name/type/cmd + deviceId(持久指纹)/udpPort/tcpPort；
// N5 可见性门控（stealth 跳过、paired 档低频）同样纯函数化，随机数由调用方注入可测。

import 'dart:math' show Random;

/// 隐身时跳过主动广播（stealth 档或旧兼容位），仅保留单播回包。
bool shouldSkipBroadcast({
  required String visibility,
  required bool stealthMode,
}) => visibility == 'stealth' || stealthMode;

/// 仅配对档是否允许本次广播：有已配对设备 always；无配对时仅 roll==0 放行（1/6 概率）。
bool allowPairedBroadcast({required int pairedCount, required int roll0to5}) {
  if (pairedCount > 0) return true;
  return roll0to5 == 0;
}

/// 是否仅配对可见档。
bool isPairedOnlyVisibility(String visibility) => visibility == 'paired';

/// 配对档掷骰（0~sides-1；测试可经 fixed 固定）。
int rollPairedDice({Random? random, int sides = 6, int? fixed}) {
  if (fixed != null) return fixed;
  return (random ?? Random()).nextInt(sides);
}

/// 广播目标端口集合（纯函数）：协议默认端口起连续 [attempts] 个候选
/// （与 udp_port_probe 探测回退范围一致，覆盖对端绑定回退端口）
/// ∪ 本端实际绑定端口，去重升序。修复：原来只发本端端口，任一端
/// 回退后两端广播互相错过（单通，仅 mDNS 兜底可救移动端方向）。
List<int> announceTargetPorts(int defaultPort, int ownPort, {int attempts = 10}) {
  final set = <int>{
    for (int i = 0; i < attempts; i++) defaultPort + i,
    ownPort,
  };
  final list = set.toList()..sort();
  return list;
}

/// 组装上线宣告/单播回包载荷（deviceId 为空不带，旧端忽略多余字段）。
Map<String, dynamic> buildAnnouncePayload({
  required String localIp,
  required String deviceName,
  required String deviceType,
  required String cmd,
  required String deviceId,
  required int udpPort,
  required int tcpPort,
}) {
  return {
    'id': localIp,
    'senderIp': localIp,
    'name': deviceName,
    'type': deviceType,
    'cmd': cmd,
    if (deviceId.isNotEmpty) 'deviceId': deviceId,
    'udpPort': udpPort,
    'tcpPort': tcpPort,
  };
}

/// 单播回包目标端口：已知对端通告端口优先，否则默认端口。
int resolveReplyPort({int? knownUdpPort, required int defaultPort}) =>
    knownUdpPort ?? defaultPort;
