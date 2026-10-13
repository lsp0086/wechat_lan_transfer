// E1：ACK 确认纯决策。从 ChatPage._onMsgAckReceived 抽出，可单测。
// blocked=true 时仅 sending 消息标失败；blocked=false 时 sending/failed 自愈 completed。

import 'package:wechat_lan_transfer/Model/chat_model.dart';

/// ACK 索引匹配：id / send_前缀 / text_前缀三者任一命中。
bool ackIndexMatches({
  required String messageId,
  required String ackMsgId,
}) =>
    messageId == ackMsgId ||
    messageId == 'send_$ackMsgId' ||
    messageId == 'text_$ackMsgId';

/// 首个 ACK 匹配下标（_onMsgAckReceived indexWhere 收敛）。
int findAckIndex<T>(
  List<T> list,
  String Function(T m) idOf,
  String ackMsgId,
) {
  for (var i = 0; i < list.length; i++) {
    if (ackIndexMatches(messageId: idOf(list[i]), ackMsgId: ackMsgId)) {
      return i;
    }
  }
  return -1;
}

/// 首个取消匹配下标（_onFileCancelReceived indexWhere 收敛，谓词由调用方拼好）。
int findCancelIndex<T>(List<T> list, bool Function(T m) matches) {
  for (var i = 0; i < list.length; i++) {
    if (matches(list[i])) return i;
  }
  return -1;
}

/// 是否有活动态消息（离页确认 any 收敛）。
bool hasActiveMessage<T>(
  List<T> list,
  TransferState Function(T m) stateOf,
  bool Function(TransferState s) isActive,
) {
  for (final m in list) {
    if (isActive(stateOf(m))) return true;
  }
  return false;
}

/// blocked ACK 是否应标记失败：仅 sending 状态才标失败（completed/failed 不动）。
bool shouldMarkBlockedFailed(TransferState current) =>
    current == TransferState.sending;

/// 正常 ACK 是否应标记完成：sending/failed 自愈 completed，其余不动。
bool shouldMarkAckCompleted(TransferState current) =>
    current == TransferState.sending || current == TransferState.failed;

/// 拉黑同步批量结果：被标记 ids + 更新后列表 + 是否有变化。
/// P0-5/方案2：仅“我发的 sending”标 failed，其余不动（纯函数可单测）。
({List<ChatMessage> messages, Set<String> ids, bool changed})
    applyBlockSyncFailed(List<ChatMessage> chatData) {
  final ids = <String>{};
  var changed = false;
  final messages = <ChatMessage>[];
  for (final m in chatData) {
    if (m.isMe && shouldMarkBlockedFailed(m.transferState)) {
      ids.add(m.id);
      messages.add(m.copyWith(transferState: TransferState.failed));
      changed = true;
    } else {
      messages.add(m);
    }
  }
  return (messages: messages, ids: ids, changed: changed);
}
