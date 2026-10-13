// E1：对端在线状态机。从 ChatListPage 抽出（在线集合 + legacy 升级编排）。
// UI/持久化副作用经回调注入（onChanged 落盘，onLegacyUpgraded 迁移配置/缓存）。

import 'package:wechat_lan_transfer/Model/device_info.dart';

class PeerPresence {
  /// 在线设备身份键集合。
  final Set<String> onlineIds = {};

  final void Function()? onChanged;
  final void Function(String oldKey, String newKey)? onLegacyUpgraded;

  PeerPresence({this.onChanged, this.onLegacyUpgraded});

  /// 标记在线；返回是否首次上线（供离线重推等一次性动作）。
  bool markOnline(String deviceKey) {
    final isNew = onlineIds.add(deviceKey);
    if (isNew) onChanged?.call();
    return isNew;
  }

  /// 标记离线（集合变化时通知调用方落盘）。
  void markOffline(String deviceKey) {
    if (onlineIds.remove(deviceKey)) onChanged?.call();
  }

  /// P0-7：legacy（IP 键）设备升级为 deviceId 键。
  /// 返回 true 表示发生了升级（调用方经 onLegacyUpgraded 迁移配置/缓存）。
  bool upgradeLegacy(DeviceInfo d, String deviceId) {
    final oldKey = d.id;
    if (oldKey == deviceId) return false;
    d.id = deviceId;
    onlineIds.remove(oldKey);
    onlineIds.add(deviceId);
    onLegacyUpgraded?.call(oldKey, deviceId);
    return true;
  }
}
