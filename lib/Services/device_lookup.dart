// E1：广播/设备查找纯函数。从 ChatListPage._handleIncomingBroadcast 与
// 身份键定位查找残留抽出，可单测。

import 'dart:convert';

/// 广播超大门控（默认 64KB）。
bool isOversizeBroadcast(String raw, {int limitBytes = 64 * 1024}) =>
    raw.length > limitBytes;

/// 单播握手成功文案：i_see_you 已握手，否则在线。
String onlineLabelForCmd(String cmd) =>
    cmd == 'i_see_you' ? '已通过单播握手成功' : '在线';

/// 是否应直接回包：iamalive 且本端非移动、对方为 mobile 才回。
bool shouldDirectReply({
  required String cmd,
  required String type,
  required bool isMobile,
}) =>
    cmd == 'iamalive' && !isMobile && type == 'mobile';

/// UDP/TCP 端口归一：载荷缺失回退 srcPort/默认端口。
int normalizeUdpPort(Map m, int? srcPort, int fallback) {
  final v = int.tryParse('${m['udpPort'] ?? ''}');
  return v ?? srcPort ?? fallback;
}

int normalizeTcpPort(Map m, int fallback) {
  final v = int.tryParse('${m['tcpPort'] ?? ''}');
  return v ?? fallback;
}

/// mDNS 自身过滤。
bool isSelfMdns({
  required String ip,
  required String? localIp,
  required List<String> localList,
}) =>
    ip == localIp || localList.contains(ip);

/// mDNS 设备键：deviceId 为空回退 ip。
String mdnsDeviceKey({required String deviceId, required String ip}) =>
    deviceId.isNotEmpty ? deviceId : ip;

/// 广播解码：双重 JSON（字符串再解一次）→ Map，不合规返回 null。
Map<String, dynamic>? decodeBroadcastMap(String rawData) {
  try {
    dynamic decoded = jsonDecode(rawData);
    if (decoded is String) decoded = jsonDecode(decoded);
    if (decoded is! Map) return null;
    return Map<String, dynamic>.from(decoded);
  } catch (_) {
    return null;
  }
}

/// 广播设备名/类型回退（缺失时未知设备/mobile）。
String broadcastNameOf(Map m) => '${m['name'] ?? "未知设备"}';
String broadcastTypeOf(Map m) => '${m['type'] ?? "mobile"}';

/// 是否广播心跳命令（iamalive/i_see_you 才处理）。
bool isHeartbeatCmd(String cmd) => cmd == 'iamalive' || cmd == 'i_see_you';

/// 新设备上线默认文案。
String newDeviceOnlineText() => '刚刚上线';

/// mDNS 在线默认文案。
String mdnsOnlineText() => '在线（mDNS）';

/// 配对弹窗门控：指纹键、未配对、未拉黑、未在流程中才弹。
bool shouldShowPairing({
  required bool isFingerprintKey,
  required bool paired,
  required bool blocked,
  required bool inProgress,
}) =>
    isFingerprintKey && !paired && !blocked && !inProgress;

/// 通知 UI 动作：会话已决策后续文件静默；聊天页打开仅 toast，否则弹窗。
enum NotifyUiAction { silent, toast, dialog }

/// 通知 UI 决策（纯判定可单测，toast/dialog 挂载留宿主）。
NotifyUiAction resolveNotifyUiAction({
  required bool sessionAccepted,
  required bool mounted,
  required bool chatOpen,
}) {
  if (sessionAccepted) return NotifyUiAction.silent;
  if (!mounted) return NotifyUiAction.silent;
  return chatOpen ? NotifyUiAction.toast : NotifyUiAction.dialog;
}

/// 设备名回退查找：列表命中取首名，否则回退 IP（三处重复收敛）。
String resolveDeviceDisplayName(
  List<({String id, String name})> devices,
  String deviceKey,
  String fallbackIp,
) {
  for (final d in devices) {
    if (d.id == deviceKey) return d.name;
  }
  return fallbackIp;
}

/// 倒序精确匹配下标（pending 拒绝/file_cancel 两路共用模板收敛）。
int findLastMatchingIndex<T>(
  List<T> cached,
  bool Function(T m) predicate,
) {
  for (var i = cached.length - 1; i >= 0; i--) {
    if (predicate(cached[i])) return i;
  }
  return -1;
}

/// 正序首个匹配下标（消息 id/taskId 三十余处 indexWhere 收敛）。
int findFirstIndexById<T>(
  List<T> list,
  String Function(T m) idOf,
  String id,
) {
  for (var i = 0; i < list.length; i++) {
    if (idOf(list[i]) == id) return i;
  }
  return -1;
}

/// 正序首个 taskId 匹配下标（传输进度/重传两路共用）。
int findFirstIndexByTaskId<T>(
  List<T> list,
  String? Function(T m) taskIdOf,
  String taskId,
) {
  for (var i = 0; i < list.length; i++) {
    if (taskIdOf(list[i]) == taskId) return i;
  }
  return -1;
}

/// 是否含指定 id（离页确认/缓冲分流 any 收敛）。
bool containsId<T>(List<T> list, String Function(T m) idOf, String id) {
  for (final m in list) {
    if (idOf(m) == id) return true;
  }
  return false;
}

/// 是否含指定 taskId（缓冲分流 any 收敛）。
bool containsTaskId<T>(
  List<T> list,
  String? Function(T m) taskIdOf,
  String taskId,
) {
  for (final m in list) {
    if (taskIdOf(m) == taskId) return true;
  }
  return false;
}

/// 可见性 toast 文案。
String visibilityToast(String v) {
  if (v == 'paired') return '已切换：仅已配对设备可见';
  if (v == 'stealth') return '已切换：隐身模式';
  return '已切换：所有人可见';
}

/// 是否隐身。
bool stealthForVisibility(String v) => v == 'stealth';

/// 端口回退文案。
String udpFallbackText(int prefer, int actual) =>
    'UDP 端口 $prefer 被占用，已改用 $actual';
String tcpFallbackText(int prefer, int actual) =>
    'TCP $prefer 被占用，已改用 $actual';
String tcpUpdatedText(int actual) => 'TCP 端口已更新为 $actual';
String firewallAddedText(int tcp, int udp) =>
    '防火墙规则已添加（TCP $tcp / UDP $udp）';
String deviceNoResponseText(int port) => '设备无响应，请检查 IP 与 UDP 端口 $port';
String joinFallback(String? a, String b) =>
    a == null || a.isEmpty ? b : '$a；$b';

// E1：下标取元收敛（-1 表未命中回 null）。
T? pickByIndex<T>(List<T> l, int idx) => idx == -1 ? null : l[idx];

// E1：命中下标判定收敛（-1 表未命中）。
bool hasMatchIndex(int idx) => idx != -1;

// E1：UDP 回退提示门控收敛（绑定端口与首选不一致才提示）。
bool needsUdpFallbackHint(int bound, int pref) => bound != pref;

// E1：命中下标判定（index != -1 收敛，chat_page/chat_list 共用）。
bool hasFoundIndex(int idx) => idx != -1;

// E1：未命中下标判定（index == -1 早退收敛）。
bool isMissingIndex(int idx) => idx == -1;

// E1：接收消息 ID 匹配判定（lastWhere/cache 查找收敛）。
bool matchesRecvId(String? id, String want) => id == want;

// E1：mDNS UDP 端口回退收敛（缺失回 fallback 默认端口）。
int resolveMdnsUdpPort(int? p, int fallback) => p ?? fallback;

// E1：TCP 端口回退判定收敛（绑定与首选不一致即回退）。
bool isTcpFallback(int bound, int pref) => bound != pref;

// E1：通知展示判定收敛（非 silent 才展示，枚举构造留宿主）。
bool shouldShowNotify(String actionName) => actionName != 'silent';

// E1：广播命令回退收敛（缺失回空串）。
String broadcastCmdOf(Map m) => '${m['cmd'] ?? ''}';
