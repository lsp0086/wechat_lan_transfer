// E1/U2：分享意图归类。从 ChatListPage._handleSharedMedia 抽出的纯函数，可单测。
// 跳过 url 类型；text 取 path trim；非 text 取 path；空值由调用方做存在性检查。

/// 分享项归类：text/file/skip（skip 含 url 与空内容）。
typedef ShareKind = String; // 'text' | 'file' | 'skip'

/// 单项归类：返回 (kind, text, path)，text/file 二选一有值。
({ShareKind kind, String? text, String? path}) classifyShareItem({
  required String type,
  required String path,
}) {
  if (type == 'url') return (kind: 'skip', text: null, path: null);
  if (type == 'text') {
    final text = path.trim();
    if (text.isEmpty) return (kind: 'skip', text: null, path: null);
    return (kind: 'text', text: text, path: null);
  }
  if (path.isEmpty) return (kind: 'skip', text: null, path: null);
  return (kind: 'file', text: null, path: path);
}

// E1：分享跳过判定收敛。
bool isSkipShare(({String kind, String? text, String? path}) r) =>
    r.kind == 'skip';

// E1：分享文本取值收敛（text 取 text，否则 null）。
String? shareTextOf(({String kind, String? text, String? path}) r) =>
    r.kind == 'text' ? r.text : null;

// E1：分享路径取值收敛（file 取 path，否则 null）。
String? sharePathOf(({String kind, String? text, String? path}) r) =>
    r.kind == 'file' ? r.path : null;

// E1：单路径转可空列表收敛（宿主 pendingFilePaths 用）。
List<String>? singlePathListOrNull(String? path) =>
    path == null ? null : [path];
