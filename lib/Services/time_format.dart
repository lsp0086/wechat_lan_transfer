// E1：从 ChatListPage 抽出的纯函数，无状态、可单测。

/// 「上次在线」相对时间。超过 7 天显示月/日。
String formatLastSeen(DateTime dt, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(dt);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
  if (diff.inHours < 24) return '${diff.inHours}小时前';
  if (diff.inDays < 7) return '${diff.inDays}天前';
  return '${dt.month}/${dt.day}';
}

/// T3 剩余时间：null/负数返回 null（UI 隐藏），>=60 秒显示 x分y秒。
String? formatEta(int? seconds) {
  if (seconds == null || seconds < 0) return null;
  if (seconds >= 60) return '${seconds ~/ 60}分${seconds % 60}秒';
  return '$seconds秒';
}
