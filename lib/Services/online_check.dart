// E1：在线发送门控。从 ChatPage._checkTargetOnline 抽出的纯决策，可单测。
// IO（toast/ping）留宿主；此处只判“拦截原因 / 放行 / 需 ping”。

/// 发送前在线检查决策。
enum OnlineGate { blocked, offlineKnown, freshOk, needPing }

/// 纯决策：blocked 优先 → 已知离线 → 心跳新鲜放行 → 否则需 ping。
OnlineGate decideOnlineGate({
  required bool blocked,
  required bool knownOnline,
  required Duration? heartbeatAge,
  required Duration freshWindow,
}) {
  if (blocked) return OnlineGate.blocked;
  if (!knownOnline) return OnlineGate.offlineKnown;
  if (heartbeatAge != null && heartbeatAge < freshWindow) {
    return OnlineGate.freshOk;
  }
  return OnlineGate.needPing;
}

/// ping 结果映射：不可达视为离线（调用方 toast），可达放行。
bool mapPingResult(bool reachable) => reachable;

/// 批量发送前置门控：空列表或离线直接返回（_sendBatchFiles if|| 收敛）。
bool shouldAbortBatchSend({required bool empty, required bool online}) =>
    empty || !online;
