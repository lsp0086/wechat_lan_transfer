// E1：T2 批量会话决策。从 ChatListPage 抽出的无状态模块，可单测。
// 一次同意/拒绝管整批，后到同 session 文件自动沿用。

import 'dart:math' show Random;

import 'transfer_limits.dart';

/// 会话级一次同意/拒绝。容量上限，超限清空防内存增长。
class SessionTracker {
  SessionTracker({this.capacity = kMaxSessionCount});

  final int capacity;
  final Set<String> acceptedSessions = {};
  final Set<String> rejectedSessions = {};

  void remember(String sessionId, bool accepted) {
    if (accepted) {
      if (acceptedSessions.length >= capacity) acceptedSessions.clear();
      acceptedSessions.add(sessionId);
    } else {
      if (rejectedSessions.length >= capacity) rejectedSessions.clear();
      rejectedSessions.add(sessionId);
    }
  }

  bool isAccepted(String? sessionId) =>
      sessionId != null && acceptedSessions.contains(sessionId);

  bool isRejected(String? sessionId) =>
      sessionId != null && rejectedSessions.contains(sessionId);
}

/// 已自动 accept 的文件键（transferId 优先）。
/// 防手动重复 accept 覆盖 token 导致在途 TCP 握手失败，TCP 到达/超时后清理。
class AutoAcceptedGuard {
  final Set<String> ids = {};

  bool contains(String key) => ids.contains(key);
  void add(String key) => ids.add(key);
  void remove(String? key) {
    if (key != null && key.isNotEmpty) ids.remove(key);
  }
}

/// P0-4 手动同意文件标识（deviceKey -> transferId/fileName 集合，E1 纯容器抽取可单测）。
/// 防止 file_notify 再次 reject；消费一次即删。
class ManualAcceptStore {
  final Map<String, Set<String>> accepted = {};

  void add(String deviceKey, String acceptKey) {
    accepted.putIfAbsent(deviceKey, () => <String>{}).add(acceptKey);
  }

  /// 命中返回 true 并移除（一次消费）；未命中返回 false。
  bool take(String deviceKey, String acceptKey) =>
      accepted[deviceKey]?.remove(acceptKey) ?? false;
}

/// T2 批量序号后缀：会话批量（count>1）返回 ' (i/n)'，否则空串（E1 纯函数）。
String batchCountSuffix(String? sessionId, int? fileCount, int? fileIndex) {
  if (sessionId == null || sessionId.isEmpty) return '';
  if (fileCount == null || fileCount <= 1) return '';
  return ' (${(fileIndex ?? 0) + 1}/$fileCount)';
}

/// 通用一次性取出：transferId 非空时优先取并移除，命中即返回；
/// 否则取 fallbackKey（旧端 ip_filename 兼容键）并移除（E1 纯函数）。
T? takeByTransferIdFrom<T>(Map<String, T> map, String? transferId, String fallbackKey) {
  if (transferId != null && transferId.isNotEmpty) {
    final hit = map.remove(transferId);
    if (hit != null) return hit;
  }
  return map.remove(fallbackKey);
}

/// P0-4 file_notify 元数据（E1 纯容器抽取，可单测）。
/// key: transferId（旧端回退 ip_filename），value 含 isVoice/fileSize/sessionId 等。
class PendingFileMeta {
  final Map<String, Map<String, dynamic>> entries = {};

  void put(String key, Map<String, dynamic> meta) => entries[key] = meta;

  String? sessionOf(String key) => entries[key]?['sessionId'] as String?;

  int sizeOf(String key) => (entries[key]?['fileSize'] as num?)?.toInt() ?? 0;

  Map<String, dynamic>? take(String key) => entries.remove(key);

  /// 优先 transferId 精确取，旧端回退 fallbackKey（ip_filename）。
  Map<String, dynamic>? takeByTransferId(
    String? transferId,
    String fallbackKey,
  ) {
    if (transferId != null && transferId.isNotEmpty) {
      final hit = entries.remove(transferId);
      if (hit != null) return hit;
    }
    return entries.remove(fallbackKey);
  }
}

/// P0-4/T2 待办文件键：transferId 优先，旧端回退兼容（E1 纯函数抽取，可单测）。
String pendingMetaKey(String? transferId, String senderIp, String fileName) =>
    (transferId != null && transferId.isNotEmpty)
        ? transferId
        : '${senderIp}_$fileName';

/// accept 去重键：transferId 优先，旧端回退 fileName。
String pendingAcceptKey(String? transferId, String fileName) =>
    (transferId != null && transferId.isNotEmpty) ? transferId : fileName;

/// 超时 timer 键：transferId 优先，否则用调用方回退键（deviceKey_fileName 或 metaKey）。
String pendingTimerKey(String? transferId, String fallbackKey) =>
    (transferId != null && transferId.isNotEmpty) ? transferId : fallbackKey;

// E1：旧端兼容回退键收敛（ip_name 拼接）。
String fallbackFileKey(String ip, String? name) => '${ip}_$name';

/// 唯一短 ID：微秒 + 32 位随机盐（E1 统一 sessionId/transferId 生成，可单测）。
String newUniqueShortId(String prefix, {int? nowMicros, int? rand}) {
  final now = nowMicros ?? DateTime.now().microsecondsSinceEpoch;
  final salt = rand ?? Random().nextInt(1 << 32);
  return '${prefix}_${now}_$salt';
}

/// P1-5 pending 消息 ID：transferId 优先，旧端回退微秒+文件hash（E1 纯函数，可单测）。
String pendingMessageId(String? transferId, String fileName, {int? nowMicros}) {
  if (transferId != null && transferId.isNotEmpty) return 'pending_$transferId';
  final salt = (transferId ?? fileName).hashCode.abs() % (1 << 32);
  return newUniqueShortId('pending', nowMicros: nowMicros, rand: salt);
}

/// pending 匹配：transferId 优先精确匹配，旧端回退 fileName（E1 纯函数）。
bool pendingTransferMatches({
  required String? messageTransferId,
  required String? messageFileName,
  required String? transferId,
  required String fileName,
}) {
  if (transferId != null && transferId.isNotEmpty) {
    return messageTransferId == transferId;
  }
  return messageFileName == fileName;
}

/// P1-6 取消匹配：transferId 精确匹配优先，其次 taskId，最后文件名+传输中/等待中（E1 纯函数）。
/// 前两支不限状态（精确 ID 即命中），文件名分支仅传输中/等待中才命中。
bool pendingFileCancelMatches({
  required String? messageTransferId,
  required String? messageTaskId,
  required String? messageFileName,
  required bool messageActive,
  required String? transferId,
  required String? taskId,
  required String fileName,
}) {
  if (transferId != null &&
      transferId.isNotEmpty &&
      messageTransferId == transferId) {
    return true;
  }
  if (taskId != null && taskId.isNotEmpty && messageTaskId == taskId) {
    return true;
  }
  return messageFileName == fileName && messageActive;
}

/// S2 PIN per-IP 错误计数限流（对标 LocalSend count PIN tries，E1 纯逻辑抽取可单测）。
class PinFailLimiter {
  PinFailLimiter({this.maxFails = kPinMaxFails});

  final int maxFails;
  final Map<String, int> failsByIp = {};

  /// 记录一次失败，返回累计次数；>maxFails 时调用方静默丢弃。
  int noteFailure(String ip) {
    final fails = (failsByIp[ip] ?? 0) + 1;
    failsByIp[ip] = fails;
    return fails;
  }

  bool overLimit(String ip) => (failsByIp[ip] ?? 0) > maxFails;

  void reset(String ip) => failsByIp.remove(ip);
}

/// P1-3 文字 msgId 去重窗口：重试包只回 ACK、不再读缓存落盘。
/// E1 从 ChatListPage 抽出，可单测；默认 TTL 30 秒。
class RecvDedupWindow {
  RecvDedupWindow({this.ttl = const Duration(seconds: kRecvDedupTtlSec)});

  final Duration ttl;
  final Map<String, DateTime> seen = {};

  /// 已见过返回 true（重复）；首次见返回 false 并记录。
  bool isDuplicate(String msgId, {DateTime? now}) {
    final t = now ?? DateTime.now();
    seen.removeWhere((_, v) => t.difference(v) > ttl);
    if (seen.containsKey(msgId)) return true;
    seen[msgId] = t;
    return false;
  }
}

// E1：列表总数收敛（缓存总数/已加载数 length 直调）。
int totalCount<T>(List<T> l) => l.length;

// E1：列表快照数收敛（history hasMore 判定用）。
int snapshotCount<T>(List<T> l) => l.length;

// E1：待写串行门控收敛（上一次写入非空才等待）。
bool hasPendingWrite(Object? f) => f != null;

// E1：会话回退解析收敛（显式 session 优先，元数据兜底）。
String? resolveSession(String? sid, String? metaSession) => sid ?? metaSession;
