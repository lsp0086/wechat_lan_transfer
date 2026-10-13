// E1：chat_list 全局提示/配对文案纯函数。从 ChatListPage 残留硬编码
// 中文与到达 toast 拼接抽出，可单测。IO/弹窗留宿主。

/// 配对成功/拉黑提示。
String pairTrustedText(String name) => '已信任并配对 $name';
String pairBlockedText(String name) => '已拉黑 $name，后续消息将忽略';

/// 空间不足（手动/自动两路共用）。
String noSpaceReceiveText(String fileName) => '空间不足，无法接收: $fileName';

/// 到达 toast：标签 + 设备名 + 文件名。
String arrivalToastText({
  required String label,
  required String deviceName,
  required String fileName,
}) =>
    '$label $deviceName 发来文件: $fileName';

/// 文字到达 toast：标签 + 设备名 + 内容。
String textArrivalToastText({
  required String label,
  required String deviceName,
  required String content,
}) =>
    '$label $deviceName 发来: $content';

/// 被对端拉黑 toast。
String blockedByNameText(String name) => '$name 已将你拉黑';

/// 无在线设备（启动参数/分享两路共用，后者短版）。
String noOnlineDeviceLongText() => '暂无在线设备，启动参数文件稍后可拖拽发送';
String noOnlineDeviceShortText() => '暂无在线设备，请先在对端打开应用';

/// 端口/防火墙/手动添加失败文案。
String tcpStartFailText() => '文件接收端口启动失败，请在设置中更换 TCP 端口';
String firewallAdminText() => '添加失败，请尝试以管理员身份运行';
String firewallErrorText() => '出错了，请以管理员身份运行后重试';
String badIpText() => 'IP 格式不正确';
String handshakeFailText(int destPort) =>
    '握手失败，请检查对端 UDP 端口（当前 $destPort）';

/// 存储路径文案。
String storageMissingText() => '所选文件夹不存在';
String storageUpdatedText() => '存储位置已更新';
String storageFailText() => '更改存储位置失败';

/// PIN/身份/扫描文案。
String pinFormatErrorText() => 'PIN 格式错误：仅 4~8 位数字';
String identityResetText() => '本机身份已重置，需对端重新配对';
String identityResetFailText(Object e) => '重置身份失败: $e';
String rescanningText() => '正在重新扫描局域网...';
String scanningDeviceText() => '正在扫描...';

/// 标题/标签/空态文案。
String lanTitleText() => '局域网传输';
String msgTabLabel() => '消息';
String settingTabLabel() => '设置';
String loadingCacheText() => '正在加载本地缓存...';
String searchingLanText() => '正在搜索局域网设备...';
String localIpText(String ip) => '本机IP: $ip';
String cacheErrorTitle() => '缓存加载异常';
String retryLoadText() => '重试加载';
String sendToTitle() => '发送到';
String cancelText() => '取消';
String onlineBadgeText() => '在线';
String offlineText() => '设备已离线';
String deleteAllDoneText() => '已删除所有设备';
String deleteFailText(Object e) => '删除失败: $e';
String tcpBindFailText(Object e) => 'TCP 端口绑定失败: $e';
String noResponseDeviceText(int port) =>
    '设备无响应，请检查 IP 与 UDP 端口 $port';
String manualOnlineText() => '手动添加：在线';

/// 批量提示行（对话框内）。
String batchHintText() => '一次同意接收整批，后续文件自动接收';

/// 接收对话框：来源行/拒绝/接收按钮。
String receiveFromText(String name) => '$name 发来:';
String receiveRejectText() => '拒绝';
String receiveAcceptText() => '接收';

// E1：缓存加载日志收敛（设备数透传）。
String cacheLoadedLog(int n) => '[DeviceCache] 从缓存加载了 $n 个设备';

// E1：空间不足结果判定收敛（precheck 非空即不足）。
bool hasNoSpace(String? r) => r != null;
