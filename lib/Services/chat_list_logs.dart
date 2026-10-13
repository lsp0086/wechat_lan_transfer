// E1：chat_list 日志纯函数。从 ChatListPage 残留 debugPrint 拼接抽出，
// 返回与原字符串一致，可单测。IO/setState/导航留宿主，调用点薄委托。

/// 生命周期。
String pauseBroadcastLog() => '[ChatList] P1-N5 后台暂停广播+看门狗+mDNS巡检';
String resumeBroadcastLog() => '[ChatList] P1-N5 前台恢复广播';

/// N4 看门狗。
String watchdogBroadcastLog() => '[ChatList] N4 看门狗：广播已停，重启';
String watchdogTcpLog() => '[ChatList] N4 看门狗：TCP 服务已停，重启';
String watchdogTcpFailLog(Object e) => '[ChatList] N4 看门狗重启 TCP 失败: $e';
String watchdogDoneLog() => '[ChatList] N4 看门狗已重启服务';

/// 缓存设备。
String cacheDeviceLog(String name, String id) =>
    '[DeviceCache] 已加载缓存设备: $name ($id)';
String cacheLoadFailLog(Object e) => '加载缓存设备失败: $e';
String deviceCleanupLog(int n) =>
    '[DeviceList] 清理了 $n 个无效设备条目 (id 为 空/0.0.0.0)';

/// 配对。
String pairedLog(String name) => '[ChatList] P0-S2 已配对: $name';
String blockedNewLog(String name) => '[ChatList] P0-S2 已拉黑新设备: $name';
String blockedIgnoreLog(String key) => '[ChatList] P0-S2 忽略已拉黑设备: $key';

/// 自动接收配置。
String autoReceiveLoadedLog(Object config) =>
    '[ChatList] 加载自动接收配置: $config';
String autoReceiveSavedLog(String deviceIp, bool value) =>
    '[ChatList] 保存自动接收状态: $deviceIp -> $value';

/// 手动接收。
String manualAcceptLog(String fileName, String deviceKey) =>
    '[ChatList] 用户手动同意接收: $fileName from $deviceKey';
String manualNoSpaceLog(String fileName) =>
    '[ChatList] T4 手动接收空间不足，拒绝: $fileName';
String autoAcceptedSkipLog(String k) =>
    '[ChatList] T2 已自动同意过，跳过重复 accept: $k';
String manualRejectLog(String fileName, String deviceKey) =>
    '[ChatList] 用户手动拒绝接收: $fileName from $deviceKey';
String pendingRejectedLog(String fileName) =>
    '[ChatList] 已更新 pending 为已拒绝: $fileName';

/// 超时。
String timeoutLog(String f) => '[ChatList] ⚠️ 文件 $f 超时未收到 TCP 连接';

/// 网卡/IP 探测。
String wifiIpLog(Object? ip) => 'WiFi IP (NetworkInfo): $ip';
String nicV6Log(String name, String ip) => '发现物理网卡 IPv6: $name -> $ip';
String nicV4Log(String name, String ip) => '发现物理网卡 IP: $name -> $ip';
String noLocalIpLog() => '未能获取到任何有效的局域网网卡 IP';
String selectedIpLog(Object? selected, Object all) =>
    '最终选择主 IP: $selected (所有IP: $all)';
String tcpStartFailLog(Object e) => '[ChatList] 启动文件接收服务器失败: $e';
String lanInitFailLog(Object e) => '局域网初始化失败: $e';

/// 到达/进度。
String unmountedTaskLog() => '[ChatList] ⚠️ newTaskStream 触发但 ChatListPage 已 unmounted';
String arrivalLog({
  required String fileName,
  required String deviceIp,
  required String deviceKey,
  required bool isFolder,
  required Object? transferId,
  required String devices,
}) =>
    '[ChatList] newTaskStream: fileName=$fileName '
    'targetIp=$deviceIp deviceKey=$deviceKey isFolder=$isFolder '
    'transferId=$transferId '
    'allDevices=$devices';
String arrivalCachedLog(String fileName, String deviceKey) =>
    '[ChatList] 全局缓存文件消息: $fileName -> deviceKey=$deviceKey';
String progressLog({
  required Object taskId,
  required Object status,
  required String deviceIp,
  required String deviceKey,
  required bool isFolder,
}) =>
    '[ChatList] 全局进度: taskId=$taskId status=$status '
    'targetIp=$deviceIp deviceKey=$deviceKey isFolder=$isFolder';
String progressMissingLog(String msgId, String deviceKey) =>
    '[ChatList] 全局进度：未找到对应消息 $msgId (deviceKey=$deviceKey)';
String progressUpdatedLog(String msgId, String suffix) =>
    '[ChatList] 全局进度：已更新缓存 $msgId -> $suffix';

/// 消息管线。
String blockSyncLog(String senderIp, String peerKey, bool blocked) =>
    '[ChatList] 收到 blockSync from $senderIp (key=$peerKey): blocked=$blocked';
String fileNotifyLog({
  required String fileName,
  required String senderIp,
  required bool isFolder,
  required bool isVoice,
  required int fileSize,
  required Object? transferId,
  required Object? sessionId,
  required Object? fileCount,
  required Object? fileIndex,
  required bool autoReceive,
}) =>
    '[ChatList] 全局收到 file_notify: $fileName from $senderIp '
    'isFolder=$isFolder isVoice=$isVoice size=$fileSize '
    'transferId=$transferId '
    'sessionId=$sessionId '
    'fileCount=$fileCount '
    'fileIndex=$fileIndex '
    'autoReceive=$autoReceive';
String pinLimitDropLog(String ip) => '[ChatList] S2 PIN 错误超限，静默丢弃: $ip';
String fileRejectedLog(String fileName, Object? reason) =>
    '[ChatList] file_notify 已拒绝: $fileName reason=$reason';
String fileAcceptedLog(String fileName, int offset, int fileSize) =>
    '[ChatList] 接受文件: $fileName (resume=$offset/$fileSize)';
String fileDeferredLog(String fileName) =>
    '[ChatList] 暂不回应 file_notify: $fileName (autoReceive=false, 等待用户决定)';
String pendingDupSkipLog(String fileName) =>
    '[ChatList] 跳过重复 pending: $fileName';
String pendingCreatedLog(String fileName) =>
    '[ChatList] 已创建 pending 消息: $fileName';
String blockedAckLog(String ip) => '[ChatList] 已拉黑 $ip，回 blocked ACK';
String dedupHitLog(String mid) =>
    '[ChatList] P1-3 去重窗口命中 msgId=$mid，跳过落盘';
String textCachedLog(String content, String peerKey) =>
    '[ChatList] 全局缓存文字消息: $content -> deviceKey=$peerKey';

/// 身份键。
String legacyFallbackLog(String ip) =>
    '[ChatList] legacy 端（无 deviceId），回退以 IP 为身份键: $ip';
String legacyUpgradeLog(String old, String now) =>
    '[ChatList] P0-7 legacy 设备升级: $old -> $now';

/// 广播/发现。
String stealthSkipLog() => '[ChatList] N5 隐身模式：跳过主动广播，仅单播回包';
String pairedOnlyIdleLog() => '[ChatList] N5 仅配对档无已配对设备，仍在网但极低频广播标记';
String pairedOnlyShardLog() => '[ChatList] N5 仅配对档：广播标记分片（接收侧按指纹过滤）';
String oversizeLog(int len, String sender) =>
    '[ChatList] 丢弃超大广播包: ${len}B from=$sender';
String unknownSenderLog(Object? rawId, String senderIp, Object? payloadIp) =>
    '[ChatList] ⚠️ 无法确定发送方 IP (rawId=$rawId senderIP=$senderIp payloadIp=$payloadIp)';
String mdnsFoundLog(String name, String key, String ip) =>
    '🎉 成功跨端上线设备: $name ($key@$ip)';
String broadcastParseFailLog(Object e) => '协议数据解析出现坏损丢弃: $e';

/// 分享/单播。
String shareIntentFailLog(Object e) => '[ChatList] U2 分享意图读取失败（忽略）: $e';
String shareStreamFailLog(Object e) => '[ChatList] U2 分享流错误（忽略）: $e';
String unicastHandshakeLog(String ip) =>
    '⚡ 触发单播握手：已成功向目标 $ip 发送定向应答包';

/// 存储/设置。
String storageLoadedLog(Object? path) =>
    '[StorageConfig] 已加载自定义存储路径: $path';
String tlsOnlyLog(bool v) => '[ChatList] P0-S3 仅TLS传输: $v';
String visibilityLog(String v) => '[ChatList] N5 发现可见性: $v';
String stealthModeLog(bool v) => '[ChatList] U4 隐身模式: $v';
String storageApplyFailLog(Object e) => '应用存储路径异常: $e';
String firewallFailLog(Object e) => '[ChatList] 防火墙修复异常: $e';
String identityResetFailLog(Object e) => '[ChatList] 重置本机身份失败: $e';
String securityEventFailLog(Object e) => '[ChatList] 记录安全事件失败: $e';

/// 离线队列。
String offlineFlushLog(String deviceKey, String msgId, int queue) =>
    '[ChatList] P1-T7 离线入队: $deviceKey msgId=$msgId（队列=$queue）';
String offlineResendLog(String deviceKey, String msgId) =>
    '[ChatList] P1-T7 离线重推成功: $deviceKey msgId=$msgId';
String offlineRetainLog(Object e) => '[ChatList] P1-T7 离线重推失败保留: $e';

/// U2 启动参数（占位纯函数，调用点按需透传路径信息）。
String launchPathLog(String p) => '[ChatList] U2 启动参数: $p';

// E1：设备调试标签收敛（名+键拼接）。
String deviceDebugLabel(String name, String id) => ' $name($id)';
