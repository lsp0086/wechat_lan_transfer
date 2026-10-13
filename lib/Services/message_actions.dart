// E1：消息长按动作。从 ChatPage._buildFileActions/_buildCopyAction 抽出的纯函数，可单测。
// 返回动作标签列表，onTap 绑定留宿主（需 context/剪贴板/文件打开）。

/// 动作标签常量（宿主比较与返回共用，避免魔法字符串）。
const String kFileLocationAction = '文件位置';
const String kShareAction = '分享';
const String kCopyAction = '复制';

/// 文件消息动作：有有效路径时 [文件位置, 分享]，否则空。
List<String> fileActionLabels(String? filePath) {
  if (filePath != null && filePath.isNotEmpty) {
    return const [kFileLocationAction, kShareAction];
  }
  return const [];
}

/// 纯文本消息动作：恒为 [复制]。
List<String> copyActionLabels() => const [kCopyAction];

/// 是否桌面端（Windows/macOS/Linux 走右键，移动端走长按）。
bool isDesktopBubble(bool isWindows, bool isMacOS, bool isLinux) =>
    isWindows || isMacOS || isLinux;

/// 长按动作分发：文件已完成有路径走文件动作，否则文本非空走复制，否则空。
/// 返回 'file' | 'copy' | 'none'，宿主据此挂 _showActionBubbleFromContext。
String bubbleActionKind({
  required bool isFile,
  required String state,
  required String? filePath,
  required String content,
}) {
  if (isFile && state == 'completed' && filePath != null) return 'file';
  if (!isFile && content.isNotEmpty) return 'copy';
  return 'none';
}

// E1：气泡动作分支判定（_buildChatBubble kind == 收敛）。
bool isFileBubbleKind(String k) => k == 'file';

// E1：气泡动作分支判定（_buildChatBubble kind == 收敛）。
bool isCopyBubbleKind(String k) => k == 'copy';

// E1：文件动作标签门控（标签命中且有路径才挂动作）。
bool isFileLocationAction(String label, String want, String? path) =>
    label == want && path != null;
