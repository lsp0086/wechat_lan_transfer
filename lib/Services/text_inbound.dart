// E1：文字入站纯函数。从 ChatPage._onTextMessageReceived 抽出，可单测。
// S5 解密内容回退 + 入站 ID 生成（msgId 有则 recv_ 前缀，否则时间戳回退）。

/// 从 payload 解出展示文本：解密成功用解密文，否则 content 字段，再否则空串。
String resolveInboundTextContent({
  required String? decrypted,
  required Map<String, dynamic> payload,
}) {
  if (decrypted != null) return decrypted;
  return payload['content'] as String? ?? '';
}

/// 入站文字消息 ID：有 msgId 则 `recv_$msgId`，否则时间戳回退（调用方注入 nowMs 可测）。
String inboundTextMessageId({required String? msgId, required int nowMs}) =>
    msgId != null ? 'recv_$msgId' : 'recv_text_$nowMs';

/// 缓存去重：已有 recv_ 前缀 ID 则跳过落盘。
bool isInboundTextDuplicate({
  required List<String> cachedIds,
  required String msgId,
}) =>
    cachedIds.contains('recv_$msgId');

/// legacy 缓存迁移门控：身份键与来源 IP 不一致才迁。
bool shouldMigrateLegacyCache({
  required String peerKey,
  required String senderIp,
}) =>
    peerKey != senderIp;

/// 入站 msgId 裸取（payload['msgId'] as String? 三处重复收敛）。
String? parseInboundMsgId(Map payload) => payload['msgId'] as String?;

/// blockSync/ACK blocked 标志裸取（缺省 false）。
bool parseBlockedFlag(Map payload) => payload['blocked'] as bool? ?? false;

// E1：文字命令判定收敛（cmd 名比对）。
bool isTextCmd(String cmdName) => cmdName == 'textMessage';

// E1：入站重复丢弃判定收敛（有 id 且去重窗口命中）。
bool shouldDropDuplicate(String? id, bool dup) => id != null && dup;

// E1：回退提示存在判定收敛（端口回退 toast）。
bool hasFallbackHint(String? h) => h != null;

// E1：回退提示非空断言收敛（toast 展示用）。
String requireNonNullHint(String? h) => h!;

// E1：blockSync blocked 载荷解析收敛。
bool parseBlockedPayload(Map p) => p['blocked'] as bool? ?? false;

// E1：文字入站 msgId 解析收敛。
String? parseMsgId(Map p) => p['msgId'] as String?;

// E1：全局消息cmd判定收敛（fileCancel/blockSync/fileNotify/textMessage，调用方传cmd.name）。
bool isFileCancelCmd(String cmdName) => cmdName == 'fileCancel';
bool isBlockSyncCmd(String cmdName) => cmdName == 'blockSync';
bool isFileNotifyCmd(String cmdName) => cmdName == 'fileNotify';

// E1：设备离线回调判定收敛（status名比对，offline才处理）。
bool isOfflineStatus(String statusName) => statusName == 'offline';

// E1：手动在线标签判定收敛（manualOnlineLabel=='online'三元收敛，枚举构造留宿主）。
bool isManualOnlineLabel(String label) => label == 'online';

// E1：手动在线bool直判收敛（ok即在线，枚举构造留宿主，manualOnlineLabel三元语义等价）。
bool isManualOnline(bool ok) => ok;
