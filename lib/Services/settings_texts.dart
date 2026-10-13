// E1：设置页纯文案/门控。从 Chat/settings_tab.dart 抽出，可单测。
// 选择器挂载/持久化回调留宿主。

/// 可见性展示文案。
String visibilityLabel(String v) {
  if (v == 'paired') return '仅已配对';
  if (v == 'stealth') return '隐身';
  return '所有人';
}

/// 端口行后缀：实际与首选不一致才展示首选。
String portSuffix({required int actual, required int preferred}) =>
    actual != preferred ? '（首选 $preferred）' : '';

/// 接收 PIN 展示文案。
String receivePinLabel(String pin) =>
    pin.isEmpty ? '未启用' : '已启用（${pin.length} 位）';

/// 端口范围校验（1024–65535）。
bool isValidPort(int port) => port >= 1024 && port <= 65535;

/// 端口对话框标签/提示。
String portDialogLabel({required bool udp}) =>
    udp ? 'UDP 发现端口' : '传输端口（HTTPS）';
String portDialogTitle({required bool udp}) =>
    '修改${portDialogLabel(udp: udp)}';
String portDialogHint({required bool udp}) => udp ? '默认 8888' : '默认 53317';
String portDialogHelper() => '范围 1024–65535，占用时自动探测相邻端口';
String portRangeText() => '端口必须在 1024–65535';

/// 可见性三档选项文案。
String visibilityOptAll() => '所有人可见';
String visibilityOptPaired() => '仅已配对设备可见';
String visibilityOptStealth() => '隐身（仅单播回包）';

/// 防火墙帮助正文（平台分支纯函数，端口注入可测）。
String firewallHelpContent({
  required bool isWindows,
  required bool isMacOS,
  required bool isLinux,
  required int tcpPort,
  required int udpPort,
}) {
  if (isWindows) {
    return 'Windows：点击下方「添加防火墙规则」，或在「Windows 安全中心 → 防火墙」放行本应用。\n当前入站：TCP $tcpPort、UDP $udpPort。';
  }
  if (isMacOS) {
    return 'macOS：系统设置 → 网络 → 防火墙 → 选项，允许本应用传入连接。\n当前监听：TCP $tcpPort、UDP $udpPort。';
  }
  if (isLinux) {
    return 'Linux：sudo ufw allow $tcpPort/tcp && sudo ufw allow $udpPort/udp\n或在防火墙软件中放行对应端口。';
  }
  return '请在系统防火墙中放行 TCP $tcpPort 与 UDP $udpPort。';
}

/// 防火墙行后缀。
String firewallPortsLabel(int tcpPort, int udpPort) =>
    'TCP $tcpPort / UDP $udpPort';

/// 设置页单元格标题。
String cellManualAdd() => '手动添加设备';
String cellUdpPort() => 'UDP 发现端口';
String cellTcpPort() => '传输端口（HTTPS）';
String cellFirewallGuide() => '防火墙引导';
String cellStoragePath() => '文件存储位置';
String cellTlsOnly() => '仅TLS传输';
String cellStealth() => '隐身模式（仅单播回包）';
String cellVisibility() => '发现可见性';
String cellReceivePin() => '接收 PIN';
String cellDeleteAll() => '删除所有设备';
String cellResetIdentity() => '重置本机身份（换证）';
String cellAbout() => '关于局域网快传 v1.0';

/// 本机信息行。
String localIpLine(String ip) => '本机局域网IP: $ip';
String portsLine(int udpPort, int tcpPort) => 'UDP $udpPort  ·  TCP $tcpPort';

/// 设置页静态标题（标题/单元格/对话框共用收敛）。
String settingsTitle() => '设置';
String manualAddTitle() => '手动添加设备';
String manualAddHint() => '如 192.168.1.10:8888';
String manualAddHelper() => '格式 IP:端口，端口缺省 8888';
String storagePickTitle() => '选择文件存储文件夹';
String visibilityDialogTitle() => '发现可见性';
String receivePinTitle() => '接收 PIN';
String receivePinHelper() =>
    '启用后，对方无正确 PIN 将被拒绝。4~8 位数字，留空=关闭。';
String receivePinHint() => '例如 123456（留空关闭）';
String confirmText() => '确定';
String saveText() => '保存';
String gotItText() => '知道了';
String addRuleText() => '立即添加规则';
String firewallGuideTitle() => '防火墙引导';
String dialogCancelText() => '取消';
String dialogConfirmText() => '确定';
String resetTitle() => '重置本机身份（换证）';
String resetContent() =>
    '将删除本机证书并生成新证书，旧指纹立即失效。\n\n对端需删除旧设备记录并重新配对，确定继续？';
String resetConfirm() => '重置';
String deleteTitle() => '删除所有设备';
String deleteContent() => '确定要删除所有设备记录吗？\n\n此操作将清空全部设备列表及聊天缓存，不可恢复。';
String deleteConfirm() => '删除';
