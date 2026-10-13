import '../Services/udp_message_service.dart';

/// 设备数据模型（P2-1：从 chat_list.dart 上帝类抽出）
/// P0-7：id = 身份键（对端 deviceId，即 TLS 指纹；旧端无 deviceId 时回退 IP）
/// currentIp = 当前路由地址（DHCP 可变），发送消息时用它查目标 IP
class DeviceInfo {
  String id;
  String currentIp;
  String name;
  String type;
  String lastMsg;
  DeviceOnlineStatus onlineStatus;
  DateTime lastSeen;
  bool isBlockedByPeer = false;

  /// P1-1：对端实际 UDP / TCP 端口（发现广播携带；旧端缺省 8888/8899）
  int udpPort;
  int tcpPort;

  DeviceInfo({
    required this.id,
    String? currentIp,
    required this.name,
    required this.type,
    required this.lastMsg,
    this.onlineStatus = DeviceOnlineStatus.unknown,
    DateTime? lastSeen,
    this.udpPort = UdpMessageService.defaultMsgPort,
    this.tcpPort = 8899,
  }) : currentIp = currentIp ?? id, // P0-7：缺省回退 id（legacy：id 即 IP）
       lastSeen = lastSeen ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'id': id,
    'ip': currentIp,
    'name': name,
    'type': type,
    'lastMsg': lastMsg,
    'lastSeen': lastSeen.toIso8601String(),
    'udpPort': udpPort.toString(),
    'tcpPort': tcpPort.toString(),
  };

  factory DeviceInfo.fromJson(Map<String, dynamic> json) {
    // 空安全校验：缺少 id、id 为空或为 0.0.0.0 时拒绝加载
    final id = json['id'];
    final name = json['name'];
    if (id is! String || id.isEmpty || id == '0.0.0.0') {
      throw FormatException('设备缓存缺少有效 id: $id');
    }
    return DeviceInfo(
      id: id,
      // P0-7：旧格式无 ip 字段（id 即 IP），读入后 currentIp 回退为 id
      currentIp: json['ip'] as String?,
      name: name is String && name.isNotEmpty ? name : '未知设备',
      type: json['type'] as String? ?? 'desktop',
      lastMsg: json['lastMsg'] as String? ?? '',
      lastSeen: json['lastSeen'] != null
          ? DateTime.tryParse(json['lastSeen'] as String) ?? DateTime.now()
          : DateTime.now(),
      udpPort:
          int.tryParse('${json['udpPort'] ?? ''}') ??
          UdpMessageService.defaultMsgPort,
      tcpPort: int.tryParse('${json['tcpPort'] ?? ''}') ?? 8899,
    );
  }
}
