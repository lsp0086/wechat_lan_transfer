// E1：设备合并纯函数。从 ChatListPage._upsertDevice 抽出，可单测。
// setState/落盘留宿主。

/// 无变化判定：全部字段一致则只刷 lastSeen，不重建不落盘。
bool isDeviceUnchanged({
  required String name,
  required String type,
  required String onlineStatus,
  required String currentIp,
  required int? udpPort,
  required int? tcpPort,
  required String lastMsg,
  required String curName,
  required String curType,
  required String curOnlineStatus,
  required String curIp,
  required int? curUdpPort,
  required int? curTcpPort,
  required String curLastMsg,
}) =>
    curName == name &&
    curType == type &&
    curOnlineStatus == onlineStatus &&
    curIp == currentIp &&
    curUdpPort == udpPort &&
    curTcpPort == tcpPort &&
    curLastMsg == lastMsg;

/// 启动参数/拖拽路径 kind：目录→dir，其余→file，异常→missing。
String dirKindForEntity({required bool isDirectory}) =>
    isDirectory ? 'dir' : 'file';

/// 是否默认存储标签（默认文件夹不落盘）。
bool isDefaultStorageLabel(String label) => label == '默认文件夹';

// E1：存储落盘路径回退收敛（默认标签存空串）。
String resolveStorageSavePath(String label) =>
    isDefaultStorageLabel(label) ? '' : label;

/// 离线文字目标 IP：身份键解析失败原样返回。
String offlineTargetIp({required String deviceKey, String? currentIp}) =>
    currentIp ?? deviceKey;

// E1：设备合并索引收敛（身份键/当前 IP/历史 IP 三路匹配）。
int findDeviceMergeIndex<T>(
  List<T> list,
  String Function(T) idOf,
  String? Function(T) ipOf,
  String deviceKey,
  String peerIp,
) {
  for (var i = 0; i < list.length; i++) {
    final item = list[i];
    if (idOf(item) == deviceKey || ipOf(item) == peerIp || idOf(item) == peerIp) {
      return i;
    }
  }
  return -1;
}

// E1：拖拽条目 kind 收敛（目录→dir，其余→file）。
String dropKindForItem(bool isDir) => isDir ? 'dir' : 'file';

// E1：无效设备计数收敛（for 循环计数，可单测）。
int countInvalidDevices<T>(List<T> list, bool Function(T) isInvalid) {
  var count = 0;
  for (final item in list) {
    if (isInvalid(item)) count++;
  }
  return count;
}

// E1：无效设备移除收敛（removeWhere，落盘留宿主）。
void removeInvalidDevices<T>(List<T> list, bool Function(T) isInvalid) {
  list.removeWhere(isInvalid);
}

// E1：缓存错误展示判定收敛（非空即展示）。
bool shouldShowCacheError(Object? err) => err != null;

// E1：设备键匹配收敛（拉黑清理按身份键比对）。
bool matchesDeviceKey(String id, String key) => id == key;

// E1：身份键 IP 匹配收敛（id 直命或当前路由 IP 命中）。
bool matchesIp({required String id, required String? curIp, required String ip}) =>
    id == ip || curIp == ip;

// E1：legacy 键判定收敛（当前键与目标不一致即旧键）。
bool isLegacyKey(String cur, String key) => cur != key;

// E1：广播地址比对收敛（子网广播去重用）。
bool sameBroadcast(String a, String b) => a == b;

// E1：设备计数收敛（列表长度）。
int deviceCount(List l) => l.length;
