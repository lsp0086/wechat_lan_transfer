// E1：设备 tile 元信息纯函数。从 ChatListPage._buildDeviceItem/
// _pickTargetDevice 抽出，可单测。弹窗挂载留宿主。

import 'transfer_limits.dart';

/// 是否手机类型。
bool isMobileType(String type) => type == 'mobile';

/// 在线设备过滤。
List<T> filterOnline<T>(
  List<T> all,
  Set<String> onlineIds,
  String Function(T) idOf,
) =>
    all.where((d) => onlineIds.contains(idOf(d))).toList();

/// 离线设备过滤（在线取反，批量收敛离线分支内联）。
List<T> filterOffline<T>(
  List<T> all,
  Set<String> onlineIds,
  String Function(T) idOf,
) =>
    all.where((d) => !onlineIds.contains(idOf(d))).toList();

/// 在线分区：一次遍历同时收敛在线/离线两分支，避免两次 where。
Map<bool, List<T>> partitionByOnline<T>(
  List<T> all,
  Set<String> onlineIds,
  String Function(T) idOf,
) {
  final online = <T>[];
  final offline = <T>[];
  for (final d in all) {
    if (onlineIds.contains(idOf(d))) {
      online.add(d);
    } else {
      offline.add(d);
    }
  }
  return {true: online, false: offline};
}

/// 在线优先排序：在线在前，保持原相对顺序（稳定收敛列表内联排序）。
/// E1：经 partitionByOnline 单次遍历实现，避免两次 where。
List<T> sortOnlineFirst<T>(
  List<T> all,
  Set<String> onlineIds,
  String Function(T) idOf,
) {
  final parts = partitionByOnline(all, onlineIds, idOf);
  return [...parts[true]!, ...parts[false]!];
}

/// Tile 配色（ARGB int，保持纯函数可测；宿主再包 Color）。
/// 手机在线绿底/离线灰底；桌面在线蓝底/离线灰底。
int tileIconBg({required bool isMobile, required bool isOnline}) {
  if (!isOnline) return 0xFFF5F5F5;
  return isMobile ? 0xFFE8F5E9 : 0xFFE3F2FD;
}

/// Tile 图标前景：在线按类型绿/蓝，离线灰（宿主用 Colors.grey 时传 null 占位）。
/// 返回 null 表示用宿主默认灰。
int? tileIconFg({required bool isMobile, required bool isOnline}) {
  if (!isOnline) return null;
  return isMobile ? 0xFF07C160 : 0xFF1976D2;
}

/// Tile 视觉三件套：图标/底色/前景（两处 ListTile/_buildDeviceItem 共用收敛）。
/// iconMobile=true 用手机图标，否则桌面图标，由宿主据 bool 选 IconData。
({bool iconMobile, int bg, int? fg}) resolveDeviceTileVisual({
  required bool isMobile,
  required bool isOnline,
}) =>
    (
      iconMobile: isMobile,
      bg: tileIconBg(isMobile: isMobile, isOnline: isOnline),
      fg: tileIconFg(isMobile: isMobile, isOnline: isOnline),
    );

/// Tile 容器底：在线浅绿白，离线纯白。
int tileContainerBg({required bool isOnline}) =>
    isOnline ? 0xFFF9FFF9 : 0xFFFFFFFF;

/// Tile 在线描边：在线绿框，否则空（纯判定，宿主据此挂 Border）。
bool showTileOnlineRing({required bool isOnline}) => isOnline;

/// 设备名样式：在线 w600/black87，否则 w500/black54（返回 ARGB + 字重名）。
({int weight, int color}) deviceNameStyle({required bool isOnline}) =>
    isOnline ? (weight: 600, color: 0xDE000000) : (weight: 500, color: 0x8A000000);

/// Tile 副文本色（ARGB int；在线灰600，否则灰400，去两处三元）。
int tileSubtitleColor({required bool isOnline}) =>
    isOnline ? 0xFF757575 : 0xFFBDBDBD;

/// 底部导航图标：选中实心，否则描边（纯判定可单测）。
bool useSolidTabIcon({required int currentIndex, required int tabIndex}) =>
    currentIndex == tabIndex;

/// 拖拽启用门控：桌面端 + 缓存就绪 + 无遮挡聊天页。
bool dropEnabled({
  required bool isDesktop,
  required bool loadingCache,
  required bool hasOpenChat,
}) =>
    isDesktop && !loadingCache && !hasOpenChat;

/// 无效设备谓词（id 空或 0.0.0.0）。
/// E1：抽至 transfer_limits.kInvalidIp。
bool isInvalidDeviceId(String id) => id.isEmpty || id == kInvalidIp;

/// 在线等待轮询次数（默认 15 次 × 1s）。
/// E1：上限抽至 transfer_limits.kLaunchSendWaitSec。
bool shouldKeepWaitingOnline({
  required int tried,
  int maxTries = kLaunchSendWaitSec,
}) =>
    tried < maxTries;

// E1：在线设备过滤收敛（_pickTargetDevice 内联 where 收敛）。
List<T> filterOnlineDevices<T>(
  List<T> all,
  Set<String> onlineIds,
  String Function(T) idOf,
) =>
    all.where((d) => onlineIds.contains(idOf(d))).toList();

// E1：手动设备在线标签收敛（ok→'online'/'unknown'，枚举构造留宿主）。
String manualOnlineLabel({required bool ok}) => ok ? 'online' : 'unknown';

// E1：tile 图标手机判定收敛（宿主据 bool 选 IconData）。
bool tileIconIsMobile({required bool iconMobile}) => iconMobile;

// E1：tile 前景存在判定收敛（有 fg 才包 Color）。
bool hasTileFg(int? fg) => fg != null;

// E1：设备名字重在线判定收敛（在线 w600）。
bool isOnlineNameWeight({required int weight}) => weight == 600;

// E1：后台暂停广播判定收敛（paused/inactive 才停）。
bool shouldPauseBroadcast(String stateName) =>
    stateName == 'paused' || stateName == 'inactive';

// E1：广播重启判定收敛（timer 空或非活跃才重启）。
bool needsBroadcastRestart({required bool isNull, required bool isActive}) =>
    isNull || !isActive;

// E1：tile 前景回退收敛（缺省品牌绿）。
int resolveFgColor({int? fg, int fallback = 0xFF07C160}) => fg ?? fallback;

// E1：空设备判定收敛（sortedDevices 空即空态）。
bool hasNoDevices({required bool isEmpty}) => isEmpty;

// E1：开聊集合判定收敛（非空即有打开聊天页）。
bool hasOpenChat(Set s) => s.isNotEmpty;

// E1：本地 IP 缺失判定收敛（优选 IP 为空）。
bool hasNoLocalIp(String? ip) => ip == null;

// E1：前台 resumed 判定收敛（生命周期名比对）。
bool isResumedState(String s) => s == 'resumed';

// E1：广播 timer 活跃判定收敛（有 timer 且活跃）。
bool isBroadcastActive({required bool hasTimer, required bool isActive}) =>
    hasTimer && isActive;

// E1：拖拽高亮判定收敛（拖拽即高亮，装饰挂载留宿主）。
bool hasDragHighlight(bool dragging) => dragging;

// E1：tile 前景值收敛（复用 resolveFgColor，缺省品牌绿）。
int tileFgValue(int? fg, int fallback) => resolveFgColor(fg: fg, fallback: fallback);

// E1：tile 前景色 int 收敛（无 fg 回退灰 0xFF9E9E9E，宿主包 Color）。
int tileFgColorOrGrey(int? fg) =>
    hasTileFg(fg) ? tileFgValue(fg, 0xFF07C160) : 0xFF9E9E9E;

// E1：tile 头像尺寸/分隔线魔法数字收敛（UI 层原值，宿主只留布局挂载）。
double tileAvatarSize() => 48.0;
double sepThickness() => 0.5;
double sepIndent() => 74.0;
