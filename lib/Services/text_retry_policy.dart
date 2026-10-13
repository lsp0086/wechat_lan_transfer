// E1：文字重传纯函数。从 ChatPage._ackTimeoutFor/_isRecvDuplicate/
// _sendTextWithRetry/_emitQueuedText 抽出，可单测。行为不变。

import 'transfer_limits.dart';

/// ACK 指数退避：base * 2^retry（默认 0.8s/1.6s/3.2s/6.4s）。
Duration ackTimeoutFor(int retry, {int baseMs = kAckBaseTimeoutMs}) =>
    Duration(milliseconds: baseMs * (1 << retry));

/// 首发去重门控：retry==0 且已在 pending 才跳过。
bool shouldSkipDuplicateSend({required int retry, required bool alreadyPending}) =>
    retry == 0 && alreadyPending;

/// 拉黑即放弃重试（本地拉黑或被对端拉黑）。
bool shouldAbortTextRetry({
  required bool blockedLocal,
  required bool blockedByPeer,
}) =>
    blockedLocal || blockedByPeer;

/// 下一次重试序号。
int nextTextRetry(int retry) => retry + 1;

// E1：进度节流上次时刻回退（无记录按 0 处理）。
int lastProgressTickOrZero(Map<String, int> ticks, String id) => ticks[id] ?? 0;

/// 是否已达最大重试（默认 3 次）。
/// E1：抽至 transfer_limits.kMaxTextRetries。
bool shouldGiveUpText(int next, {int maxRetries = kMaxTextRetries}) =>
    next > maxRetries;

/// 接收端 msgId 去重：窗口内命中或 chatData 已有 recv_ 前缀都算重复。
/// 调用方负责把 now 写入 recent（保持原副作用语义）。
bool isRecvDuplicate({
  required Map<String, DateTime> recent,
  required String msgId,
  required DateTime now,
  required Duration ttl,
  required bool existsInChat,
}) {
  recent.removeWhere((_, t) => now.difference(t) > ttl);
  if (recent.containsKey(msgId)) return true;
  if (existsInChat) {
    recent[msgId] = now;
    return true;
  }
  recent[msgId] = now;
  return false;
}

/// 发送进度 80ms 节流：now-last < gap 才跳过。
/// E1：抽至 transfer_limits.kProgressThrottleMs。
bool shouldThrottleProgress({
  required int lastTickMs,
  required int nowMs,
  int gapMs = kProgressThrottleMs,
}) =>
    nowMs - lastTickMs < gapMs;

/// ACK 定时器单条取消：map 移除 + cancel + 重试计数清理（三处重复收敛）。
/// 泛型保持调用方 `Map<String, Timer>` 类型安全。
void cancelAckTimer<T>(
  Map<String, T> pending,
  Map<String, int> retries,
  String msgId,
  void Function(T timer) cancel,
) {
  final timer = pending.remove(msgId);
  if (timer != null) cancel(timer);
  retries.remove(msgId);
}

/// ACK 定时器批量取消（blockSync 拉黑批量失败用）。
void cancelAckTimersForIds<T>(
  Map<String, T> pending,
  Map<String, int> retries,
  Iterable<String> ids,
  void Function(T timer) cancel,
) {
  for (final id in ids) {
    cancelAckTimer(pending, retries, id, cancel);
  }
}

/// PIN 重试轮数门控：attempt < kPinRetryAttempts（file_notify→accept 等待）。
bool shouldRetryPinAttempt({required int attempt, int max = kPinRetryAttempts}) =>
    attempt < max;
