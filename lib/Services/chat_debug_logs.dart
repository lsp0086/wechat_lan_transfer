// E1：ChatPage 缓冲/追认日志纯函数（可单测，无 import）。
String bufferedTaskLog(String? fileName) =>
    '[ChatPage] 缓冲 newTask: $fileName (尚未加载完毕)';
String bufferedMsgLog(String cmd) => '[ChatPage] 缓冲 msg: $cmd (尚未加载完毕)';
String recoveredLog(String? f) => '[ChatPage] 追认已完成: $f (文件/文件夹存在磁盘)';
String bufferedEventsLog(int n) => '[ChatPage] 处理 $n 条缓冲事件';
String ignoreMsgLog(String sIp, String id, String target) =>
    '[ChatPage] 消息来自 $sIp，当前对话是 $id/$target，忽略';
String invalidIdLog(String id) => '[ChatPage] ⚠️ widget.id 无效 ("$id")，跳过 IP 过滤，接受消息';
String batchSendLog(String sid, int n) =>
    '[ChatPage] T2 批量发送: sessionId=$sid 共 $n 个';
String initChatFailLog(Object e, Object st) => '_initChat 未捕获异常: $e\n$st';
String thumbDirFailLog(Object e) => '缩略图目录初始化失败: $e';
String recoveredZipLog(String? f) => '[ChatPage] 追认解压已完成消息: $f';
String inboundLog(Object cmd, String senderIp, String id) =>
    '[ChatPage] 收到入站消息: cmd=$cmd, senderIp=$senderIp, currentChatId=$id';
String duplicateMsgLog(Object? msgId) =>
    '[ChatPage] 收到重复消息 msgId=$msgId，忽略';
String acceptLog(String fileName) =>
    '[ChatPage] 收到 file_accept，触发 pending completer: $fileName';
String resendRequestLog(String fileName, String? transferId) =>
    '[ChatPage] 收到重新发送请求: $fileName transferId=$transferId';
String resendRetryLog(String fileName) =>
    '[ChatPage] 收到重新发送请求: $fileName，重新发送';
String fileDeletedLog(String fileName) =>
    '[ChatPage] 文件已删除，无法重新发送: $fileName';
String rejectCompleterLog(String fileName, Object? reason) =>
    '[ChatPage] 收到 file_reject，触发 pending completer: $fileName reason=$reason';
String rejectLog(String fileName) => '[ChatPage] 对方拒绝接收文件: $fileName';
String notifyDupLog(String fileName) =>
    '[ChatPage] file_notify 重复，跳过: $fileName';
String pendingAddedLog(String fileName, bool autoReceive) =>
    '[ChatPage] 已添加 pending 消息到 UI: $fileName (autoReceive=$autoReceive)';
String ackBlockedLog(Object? msgId) =>
    '[ChatPage] 消息 $msgId 被对方拒收（对方已拉黑）';
String ackOkLog(Object? msgId) => '[ChatPage] 消息 $msgId 已确认送达';
String ackHealedLog() => '[ChatPage] 消息正常送达，清除 _isBlockedByPeer 状态';
String fileReceivedLog(
  Object? fileName,
  Object? isFolder,
  Object? targetIp,
  Object? filePath,
  Object? taskId,
) =>
    '[ChatPage] _onFileReceived: fileName=$fileName '
    'isFolder=$isFolder targetIp=$targetIp '
    'filePath=$filePath taskId=$taskId';
String fileIgnoreLog(Object? targetIp, Object? id, Object? target) =>
    '[ChatPage] 文件来自 $targetIp，当前对话是 $id/$target，跳过 UI 显示（ChatListPage 已全局缓存）';
String invalidFilterLog(Object? id) =>
    '[ChatPage] ⚠️ widget.id 无效 ("$id")，跳过过滤';
String taskExistsLog(Object? taskId) =>
    '[ChatPage] taskId=$taskId 已存在消息，跳过重复创建';
String retransmitLog(Object? fileName) =>
    '[ChatPage] 检测到重传：文件名=$fileName，更新旧消息而非创建新消息';
String cacheMetaLog(Object? type) =>
    '[ChatPage] 使用缓存中的消息类型/音频元数据: $type';
String cacheMetaFailLog(Object e) => '[ChatPage] 读取缓存消息类型失败: $e';
String userAcceptLog(Object? f) => '[ChatPage] 用户点击接收 pending: $f';
String userRejectLog(Object? f) => '[ChatPage] 用户点击拒绝 pending: $f';
String triggerExtractLog(Object? fileName, Object? filePath, Object? taskId) =>
    '[ChatPage] 触发解压: fileName=$fileName '
    'filePath=$filePath taskId=$taskId';
String extractSkipLog(String? path, String? name) =>
    '[ChatPage] 解压跳过: filePath=$path fileName=$name';
String nonExtractLog(Object? isFolder, Object? fileName) =>
    '[ChatPage] 接收完成但不解压: isFolder=$isFolder fileName=$fileName';
String pickFailLog(Object e) => '文件选择异常: $e';
String folderFailLog(Object e) => '文件夹发送异常: $e';
String folderPackedLog(String folderPath, String folderName, int count) =>
    '[ChatPage] dir "$folderPath" 文件夹 "$folderName" 打包完成，共 $count 个文件';
String folderZippedLog(String folderName, String sizeText) =>
    '[ChatPage] 文件夹 "$folderName" 已打包为 zip，大小: $sizeText';
String imageFailLog(Object e) => '选择图片失败: $e';
String photoFailLog(Object e) => '拍照失败: $e';
String directResendDeletedLog(String name) =>
    '[ChatPage] _directResendFile: 文件已删除，无法重新发送: $name';
String directResendFailLog(Object e) => '_directResendFile 失败: $e';
String sendMissingLog(String filePath) => '发送文件失败: 文件已被删除 $filePath';
String shaFailLog(Object e) => '[ChatPage] SHA-256 预计算失败，降级发送: $e';
String sendFailLog(Object e) => '发送文件失败: $e';
String blockSyncLog(bool blocked) =>
    '[ChatPage] 收到 blockSync: 对方${blocked ? "已" : "已解除"}拉黑';
String loadBlockFailLog(Object e) => '加载黑名单失败: $e';
String saveBlockFailLog(Object e) => '保存黑名单失败: $e';
String openLocFailLog(Object e) => '[ChatPage] 打开文件位置失败: $e';
String shareFailLog(Object e) => '[ChatPage] 分享文件失败: $e';
String sendTextStartLog() => '[ChatPage] ====== 发送文字消息 ======';
String sendTextTargetLog(String id) => '[ChatPage] 目标IP: $id';
String sendTextContentLog(String text) => '[ChatPage] 内容: "$text"';
String sendTextStatusLog(bool running, Object? localIP) =>
    '[ChatPage] 消息服务状态: running=$running, localIP=$localIP';
String sendTextDedupLog(String msgId) =>
    '[ChatPage] P1-3 去重：msgId=$msgId 已在发送中，跳过';
String abortRetryLog(String msgId, bool isBlocked) =>
    '[ChatPage] 消息 $msgId ${isBlocked ? "已拉黑对方" : "被对方拉黑"}，放弃重试';
String retryAckLog(String msgId, int next, int ms) =>
    '[ChatPage] 消息 $msgId 未收到 ACK，第 $next 次重试（退避 ${ms}ms）';
String sendTextFailLog(String msgId, int max) =>
    '[ChatPage] 消息 $msgId 发送失败（已重试 $max 次）';
String unblockSyncLog() => '[ChatPage] 拉黑已解除，发送 blockSync 通知对方可恢复发送';
String retryShaFailLog(Object e) => '[ChatPage] 重试语音 SHA-256 预计算失败: $e';
String retryAudioFailLog(Object e) => '[ChatPage] 重发音频失败: $e';
String zipSkipLog(String p) => '[ChatPage] zip 解压跳过: 文件不存在 $p';
String zipTooLargeLog(String sizeText) =>
    '[ChatPage] ⚠️ zip 过大拒绝解压: $sizeText';
String zipStartLog(String p) => '[ChatPage] 开始解压 zip: $p';
String zipCountLog(int n) => '[ChatPage] zip 内共 $n 个条目';
String zipPrefixLog(Object? c) => '[ChatPage] zip 检测到共同前缀: "$c/"，解压时将剥离';
String zipSuspiciousLog(String n) => '[ChatPage] D4 跳过可疑 zip 条目: $n';
String zipOverLimitLog(String sizeText) =>
    '[ChatPage] ⚠️ ZIP 解压中止: 累计大小超过 $sizeText';
String zipTraversalLog(String s) => '[ChatPage] ⚠️ 路径穿越拦截: $s';
String zipTraversalDirLog(String s) => '[ChatPage] ⚠️ 路径穿越拦截 (dir): $s';
String zipOverLimitCleanedLog(String p) =>
    '[ChatPage] ⚠️ ZIP 超限已清理半解压目录，保留原文件: $p';
String zipDoneLog(String folderName, int count, String sizeText) =>
    '[ChatPage] zip 已解压: $folderName ($count 个文件, $sizeText)';
String zipFailLog(Object e) => '[ChatPage] zip 解压失败: $e';
String audioMetaFailLog(Object e) => '[ChatPage] 更新音频元数据失败: $e';
String decodeSizeFailLog(Object e) => '解码图片尺寸失败: $e';
String staleCacheFailLog(Object e) => '[ChatPage] D3 陈旧缓存清理失败: $e';
String tempZipFailLog(Object e) => '[ChatPage] 临时 zip 清理失败: $e';
String thumbUnsupportedLog() => '当前平台不支持图片压缩，跳过缩略图生成';
String thumbSrcMissingLog(String p) => '缩略图生成失败: 源文件不存在 $p';
String thumbOkLog(String p) => '缩略图生成成功: $p';
String thumbFailLog(Object e) => '缩略图生成失败: $e，将使用原图显示';
String audioShaFailLog(Object e) => '[ChatPage] 语音 SHA-256 预计算失败: $e';
String udpNotifyFailLog() => '[ChatPage] UDP 文件通知发送失败';
String sendAudioFailLog(Object e) => '[ChatPage] 发送音频失败: $e';
