// E1：黑名单集合纯函数。从 ChatPage._loadBlockedState/_saveBlockedState
// 抽出，可单测。文件读写留宿主。
import 'dart:convert';

import 'package:wechat_lan_transfer/Model/chat_model.dart' show ChatMessage;

/// 解析黑名单 JSON 数组为字符串列表。
List<String> parseBlockedList(String content) =>
    (jsonDecode(content) as List<dynamic>).map((e) => e.toString()).toList();

/// content 是否包含 deviceId。
bool isDeviceBlocked(List<String> blockedList, String deviceId) =>
    blockedList.contains(deviceId);

/// 保存时合并：拉黑则加入，未拉黑则移除。
List<String> mergeBlockedList({
  required List<String> current,
  required String deviceId,
  required bool blocked,
}) {
  final next = List<String>.from(current);
  if (blocked && !next.contains(deviceId)) next.add(deviceId);
  if (!blocked) next.remove(deviceId);
  return next;
}

/// 被拉黑 ids 对应的消息子集（逐条更新缓存 for+contains 收敛，可单测）。
List<ChatMessage> filterBlockedMessages(
  List<ChatMessage> chatData,
  Set<String> blockedIds,
) =>
    [for (final m in chatData) if (blockedIds.contains(m.id)) m];

// E1：会话决策记忆门控收敛（非空串才记忆）。
bool hasSessionDecision(String? s) => s != null && s.isNotEmpty;

// E1：传输 timer 键存在判定收敛。
bool hasTransferTimerKey(String? k) => k != null && k.isNotEmpty;
