// E1：设备列表排序。从 ChatListPage._buildMessageTab 抽出的纯函数，可单测。
// 在线优先，其次按名字排序；onlineIds 以身份键集合传入。
// 新库 collection：sortedBy 复刻排序语义（在线后置布尔 + 名字），返回新列表。

import 'package:collection/collection.dart';

/// 按在线优先 + 名字排序，返回新列表（不改原列表）。
List<T> sortDevicesOnlineFirst<T>({
  required List<T> devices,
  required String Function(T d) idOf,
  required String Function(T d) nameOf,
  required Set<String> onlineIds,
}) {
  // 先按名字稳定排，再按在线分区（保持组内名字序）。
  return devices.sortedBy(nameOf).sortedBy((d) => onlineIds.contains(idOf(d)) ? 0 : 1);
}
