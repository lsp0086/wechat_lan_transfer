// E1：P1-T7 文字离线队列。从 ChatListPage 抽出的纯容器，可单测。
// 发送失败入队（deviceKey -> 待重推文字），对端上线重推成功后移除。

typedef OfflineTextItem = ({String msgId, String text});

class OfflineTextQueue {
  final Map<String, List<OfflineTextItem>> queues = {};

  /// 入队：同 deviceKey + 同 msgId 幂等跳过。
  void enqueue(String deviceKey, String msgId, String text) {
    final list = queues.putIfAbsent(deviceKey, () => []);
    if (list.any((e) => e.msgId == msgId)) return;
    list.add((msgId: msgId, text: text));
  }

  /// 取某设备的待重推列表（可空，供调用方遍历发送）。
  List<OfflineTextItem>? items(String deviceKey) => queues[deviceKey];

  /// 重推成功后移除单条；队列空则删 key。
  void removeItem(String deviceKey, OfflineTextItem item) {
    final list = queues[deviceKey];
    if (list == null) return;
    list.remove(item);
    if (list.isEmpty) queues.remove(deviceKey);
  }

  bool get isEmpty => queues.isEmpty;
  int lengthOf(String deviceKey) => queues[deviceKey]?.length ?? 0;
}
