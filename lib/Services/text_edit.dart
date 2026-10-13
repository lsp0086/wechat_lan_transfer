// E1：输入框文本编辑纯函数。从 ChatPage.insertText（emoji 插入）抽出，可单测。
// 处理 collapsed 插入 / 选区替换 / 无效选区回退三种分支，返回新文本与新光标。

/// 文本编辑结果：新文本 + 折叠光标偏移。
typedef TextEditResult = ({String text, int caret});

/// 在 [current] 的 [baseOffset, extentOffset) 处插入 [insert]。
/// 选区无效（valid=false）时回退为仅新文本（调用方光标移到末尾）。
TextEditResult applyTextInsert({
  required String current,
  required int baseOffset,
  required int extentOffset,
  required bool valid,
  required String insert,
}) {
  if (!valid) return (text: insert, caret: insert.length);
  if (baseOffset == extentOffset) {
    final end = extentOffset.clamp(0, current.length);
    final head = end > 0 ? current.substring(0, end) : '';
    final tail = current.length > end ? current.substring(end) : '';
    final text = '$head$insert$tail';
    return (text: text, caret: end + insert.length);
  }
  var start = baseOffset.clamp(0, current.length);
  var end = extentOffset.clamp(0, current.length);
  if (start > end) {
    final t = start;
    start = end;
    end = t;
  }
  final text = current.replaceRange(start, end, insert);
  return (text: text, caret: start + insert.length);
}

/// 待发送文本门控：非空才自动发送（分享/拖拽入口三处重复收敛）。
bool hasPendingText(String? s) => s != null && s.isNotEmpty;

/// 待发送文件夹门控。
bool hasPendingFolder(String? s) => s != null && s.isNotEmpty;

/// 待发送路径列表门控。
bool hasPendingPaths(List<String> l) => l.isNotEmpty;

/// 单批还是多批：1 条走直发，否则走批量会话。
bool isSinglePathBatch(int count) => count == 1;

/// 输入为空门控：PIN/文本输入取消或空串都算放弃。
bool isNullOrEmptyInput(String? s) => s == null || s.isEmpty;

// E1：列表非空判定（缓存/缓冲事件门控收敛）。
bool isNonEmptyList(Iterable l) => l.isNotEmpty;

// E1：列表为空判定（打包产物门控收敛）。
bool isEmptyList(Iterable l) => l.isEmpty;

// E1：拒绝原因有效判定（结构化原因非空才记录）。
bool hasRejectReason(String? r) => r != null && r.isNotEmpty;

// E1：zip 共同前缀有效判定（非空才剥离）。
bool hasCommonPrefix(String? p) => p != null && p.isNotEmpty;

// E1：解压安全路径为空判定（空路径跳过当前条目）。
bool isEmptyPath(String s) => s.isEmpty;

// E1：通用非空判定（纯 if != null 收敛，IO 路径内部 ! 保留）。
bool isNotNull(Object? v) => v != null;

// E1：可空 ID 为空判定（msgId == null 早退收敛，Object? 兼容各类可空）。
bool isNullId(Object? v) => v == null;

// E1：入站 msgId 非空判定。
bool hasInboundMsgId(String? v) => v != null;

// E1：取消路由判定。
bool isCancelRoute(String r) => r == 'cancel';
// E1：中止路由判定。
bool isAbortRoute(String r) => r == 'abort';

// E1：zip 解压路径门控。
bool canExtractZip(String? p, String? n) => p != null && n != null;

// E1：图片路径非空判定。
bool hasImagePath(String? p) => p != null;

// E1：文件夹发送中止门控。
bool abortFolderSend(String? p, bool mounted) => p == null || !mounted;

// E1：RenderBox 有效正向判定。
bool hasValidBox({required bool isNull, required bool hasSize}) =>
    !isNull && hasSize;
