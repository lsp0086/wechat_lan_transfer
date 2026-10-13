// E1：历史分页纯函数。从 ChatPage._loadOlderHistory 抽出，可单测。
// 输入全量 older（已过滤 init_）与当前已加载数，算出上一页切片与是否还有更早。

/// 上一页切片：[from, older.length - loadedCount)，from 按 pageSize 回退 clamp。
/// 返回 (page, from)：page 为空表示无更多；from>0 表示还有更早。
({List<T> page, int from}) olderHistoryPage<T>({
  required List<T> older,
  required int loadedCount,
  required int pageSize,
}) {
  if (older.length <= loadedCount) return (page: <T>[], from: 0);
  final from = (older.length - loadedCount - pageSize).clamp(
    0,
    older.length,
  );
  final page = older.sublist(from, older.length - loadedCount);
  return (page: page, from: from);
}

/// 是否还有更早历史（from>0 即还有）。
bool historyHasMore(int from) => from > 0;

/// 是否系统初始化消息（id 以 init_ 开头，恢复/分页时过滤）。
bool isInitSystemMessage(String id) => id.startsWith('init_');

/// 过滤掉系统初始化消息（返回新列表，不改原列表）。
List<T> withoutInitMessages<T>(List<T> all, String Function(T) idOf) =>
    all.where((m) => !isInitSystemMessage(idOf(m))).toList();

/// 是否还有更多（总数 > 已加载数）。
bool hasMoreHistory({required int total, required int loaded}) =>
    total > loaded;

// E1：滚动基准收敛（无客户端时按 0 处理）。
double scrollBaseExtent({required bool hasClients, required double maxExtent}) =>
    hasClients ? maxExtent : 0.0;

// E1：视口保持收敛（新增内容撑高后叠加偏移）。
double keepViewportOffset({required double offset, required double grew}) =>
    offset + grew;

// E1：初始化消息过滤命中判定（数量变化即需回写缓存）。
bool hasFilteredInitMessages({required int before, required int after}) =>
    before != after;

// E1：历史加载中止门控（未挂载或无更多直接返回）。
bool shouldAbortHistoryLoad({required bool mounted, required bool empty}) =>
    !mounted || empty;

// E1：无更早历史判定收敛（已过滤总数不大于已加载数）。
bool noOlderHistory({required int older, required int loaded}) =>
    older <= loaded;
