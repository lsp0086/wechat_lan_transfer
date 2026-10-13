// E1：握手（P0-S2 配对/拉黑）状态。从 ChatListPage 抽出的纯容器 +
// AppConfigStore 读写封装（TOFU：指纹即身份键）。

import 'package:wechat_lan_transfer/Services/app_config_store.dart';

class PairedDeviceStore {
  /// 已配对设备指纹集合（paired_devices.json，按 64 位 hex 指纹索引）。
  final Set<String> paired = {};

  /// 全局拉黑设备集合（blocked_devices.json；同时匹配 IP 与身份键，含 legacy 条目）。
  final Set<String> blocked = {};

  /// 加载配对 + 拉黑列表（文件损坏时保持内存缓存，调用方容错）。
  Future<void> load() async {
    try {
      final p = await AppConfigStore.readStringSet(AppConfigStore.pairedFile);
      paired
        ..clear()
        ..addAll(p);
    } catch (_) {}
    try {
      final b = await AppConfigStore.readStringSet(AppConfigStore.blockedFile);
      blocked
        ..clear()
        ..addAll(b);
    } catch (_) {}
  }

  /// 实时重读拉黑列表（与 ChatPage 的拉黑操作同步），返回最新集合。
  /// 文件损坏时回退内存缓存。
  Future<Set<String>> reloadBlocked() async {
    try {
      final b = await AppConfigStore.readStringSet(AppConfigStore.blockedFile);
      blocked
        ..clear()
        ..addAll(b);
    } catch (_) {}
    return blocked;
  }

  Future<void> savePaired() async {
    try {
      await AppConfigStore.writeStringSet(AppConfigStore.pairedFile, paired);
    } catch (_) {}
  }

  Future<void> saveBlocked() async {
    try {
      await AppConfigStore.writeStringSet(AppConfigStore.blockedFile, blocked);
    } catch (_) {}
  }

  /// 信任并配对（幂等）。
  void trust(String deviceKey) => paired.add(deviceKey);

  /// 拉黑（同时移出配对，防止配对/拉黑双态并存）。
  void block(String deviceKey) {
    paired.remove(deviceKey);
    blocked.add(deviceKey);
  }
}
