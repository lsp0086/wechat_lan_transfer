import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'chat_page.dart';
import '../Services/udp_message_service.dart';
import '../Services/message_cache_service.dart';

// 利用 Extension 扩展 Platform，优雅地补充 isMobile 属性
extension PlatformMobileExtension on Platform {
  static bool get isMobile => Platform.isAndroid || Platform.isIOS;
}

/// 设备数据模型
class _DeviceInfo {
  final String id;
  String name;
  String type;
  String lastMsg;
  DeviceOnlineStatus onlineStatus;
  DateTime lastSeen;

  _DeviceInfo({
    required this.id,
    required this.name,
    required this.type,
    required this.lastMsg,
    this.onlineStatus = DeviceOnlineStatus.unknown,
    DateTime? lastSeen,
  }) : lastSeen = lastSeen ?? DateTime.now();

  Map<String, String> toJson() => {
        'id': id,
        'name': name,
        'type': type,
        'lastMsg': lastMsg,
        'lastSeen': lastSeen.toIso8601String(),
      };

  factory _DeviceInfo.fromJson(Map<String, dynamic> json) => _DeviceInfo(
        id: json['id'] as String,
        name: json['name'] as String,
        type: json['type'] as String? ?? 'desktop',
        lastMsg: json['lastMsg'] as String? ?? '',
        lastSeen: json['lastSeen'] != null
            ? DateTime.parse(json['lastSeen'] as String)
            : null,
      );
}

class ChatListPage extends StatefulWidget {
  const ChatListPage({super.key});

  @override
  ChatListPageState createState() => ChatListPageState();
}

class ChatListPageState extends State<ChatListPage> {
  int _currentIndex = 0;

  // 设备列表（在线 + 缓存的历史设备）
  final List<_DeviceInfo> _allDevices = [];
  // 在线设备 ID 集合
  final Set<String> _onlineDeviceIds = {};

  // UDP 局域网通讯配置
  static const int _udpPort = 8888;
  RawDatagramSocket? _udpSocket;
  Timer? _broadcastTimer;
  String _localIP = "未知IP";
  String _myDeviceName = "加载中...";

  // 存储本机的所有合法 IPv4，用于精准防自锁
  final List<String> _localIPList = [];

  // 消息服务
  final UdpMessageService _msgService = UdpMessageService();
  final MessageCacheService _cacheService = MessageCacheService();

  // 设备列表缓存保存防抖
  Timer? _saveDebounceTimer;

  @override
  void initState() {
    super.initState();
    _initDeviceAndNetwork();
  }

  @override
  void dispose() {
    _broadcastTimer?.cancel();
    _saveDebounceTimer?.cancel();
    // 确保最后一次保存完成
    _saveCachedDeviceListImmediate();
    _closeUdpSocket();
    super.dispose();
  }

  // 安全关闭并释放旧 Socket
  void _closeUdpSocket() {
    try {
      _udpSocket?.close();
      _udpSocket = null;
    } catch (e) {
      debugPrint("释放 UDP Socket 异常: $e");
    }
  }

  // ================= 初始化入口：设备名与网络发现 =================
  Future<void> _initDeviceAndNetwork() async {
    await _fetchRealDeviceName();
    await _loadCachedDevices();
    await _initLanDiscovery();
  }

  // 加载缓存设备列表
  Future<void> _loadCachedDevices() async {
    try {
      final cachedDevices = await _readCachedDeviceList();
      debugPrint('[DeviceCache] 从缓存加载了 ${cachedDevices.length} 个设备');
      if (cachedDevices.isNotEmpty && mounted) {
        setState(() {
          for (final d in cachedDevices) {
            if (!_allDevices.any((e) => e.id == d.id)) {
              _allDevices.add(d);
              debugPrint('[DeviceCache] 已加载缓存设备: ${d.name} (${d.id})');
            }
          }
        });
      }
    } catch (e) {
      debugPrint("加载缓存设备失败: $e");
    }
  }

  // 保存设备列表到本地缓存（带防抖，避免高频写入）
  void _scheduleSaveDeviceList() {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      _saveCachedDeviceListImmediate();
    });
  }

  Future<void> _saveCachedDeviceListImmediate() async {
    try {
      final appDir = await _cacheService.getCacheDir();
      final file = File('$appDir/device_list.json');
      final jsonList = _allDevices.map((d) => d.toJson()).toList();
      await file.writeAsString(jsonEncode(jsonList));
      debugPrint('[DeviceCache] 已保存 ${jsonList.length} 个设备到缓存: $appDir/device_list.json');
    } catch (e) {
      debugPrint("保存设备列表失败: $e");
    }
  }

  // 读取缓存设备列表
  Future<List<_DeviceInfo>> _readCachedDeviceList() async {
    try {
      final appDir = await _cacheService.getCacheDir();
      final file = File('$appDir/device_list.json');
      debugPrint('[DeviceCache] 尝试读取缓存: $appDir/device_list.json (存在=${await file.exists()})');
      if (!await file.exists()) return [];
      final content = await file.readAsString();
      debugPrint('[DeviceCache] 缓存文件大小: ${content.length} 字节');
      final jsonList = jsonDecode(content) as List<dynamic>;
      return jsonList
          .map((j) => _DeviceInfo.fromJson(j as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[DeviceCache] 读取缓存失败: $e');
      return [];
    }
  }

  // 💡 动态获取真实设备名称
  Future<void> _fetchRealDeviceName() async {
    final deviceInfo = DeviceInfoPlugin();
    String detectedName = "未知设备";

    try {
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        detectedName = "${androidInfo.manufacturer} ${androidInfo.model}";
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        detectedName = iosInfo.name;
      } else if (Platform.isWindows) {
        final windowsInfo = await deviceInfo.windowsInfo;
        detectedName = windowsInfo.computerName;
      } else if (Platform.isMacOS) {
        final macosInfo = await deviceInfo.macOsInfo;
        detectedName = macosInfo.computerName;
      } else if (Platform.isLinux) {
        final linuxInfo = await deviceInfo.linuxInfo;
        detectedName = linuxInfo.name;
      }
    } catch (e) {
      debugPrint("读取硬件设备名失败，降级处理: $e");
      detectedName = Platform.isAndroid
          ? "Android 手机"
          : (Platform.isWindows ? "Windows 电脑" : "局域网设备");
    }

    if (mounted) {
      setState(() {
        _myDeviceName = detectedName;
      });
    }
  }

  // ================= 局域网真实扫描与广播核心逻辑 =================
  Future<void> _initLanDiscovery() async {
    _closeUdpSocket();

    try {
      String? wifiIP;
      final List<String> allValidIPs = [];
      _localIPList.clear();

      // 1. 优先尝试通过网络库获取 Wi-Fi IP
      try {
        final info = NetworkInfo();
        wifiIP = await info.getWifiIP();
        if (wifiIP != null &&
            wifiIP != "0.0.0.0" &&
            (wifiIP.startsWith('192.168.') ||
                wifiIP.startsWith('10.') ||
                wifiIP.startsWith('172.'))) {
          _localIPList.add(wifiIP);
          allValidIPs.add(wifiIP);
          debugPrint("WiFi IP (NetworkInfo): $wifiIP");
        }
      } catch (_) {}

      // 2. 遍历底层所有物理网卡
      List<NetworkInterface> interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );

      for (var interface in interfaces) {
        String name = interface.name.toLowerCase();
        if (name.contains('virtual') ||
            name.contains('vbox') ||
            name.contains('vmnet') ||
            name.contains('wsl') ||
            name.contains('vethernet') ||
            name.contains('hyper-v') ||
            name.contains('docker') ||
            name.contains('vpn') ||
            name.contains('tunnel') ||
            name.contains('loopback') ||
            name.contains('pseudo') ||
            name.contains('tap') ||
            name.contains('tun') ||
            name.contains('bridge') ||
            name.contains('bluetooth') ||
            name.contains('usb')) {
          continue;
        }

        for (var addr in interface.addresses) {
          String addressStr = addr.address;
          if (addressStr.startsWith('192.168.') ||
              addressStr.startsWith('10.') ||
              addressStr.startsWith('172.')) {
            if (!_localIPList.contains(addressStr)) {
              _localIPList.add(addressStr);
              allValidIPs.add(addressStr);
              debugPrint("发现物理网卡 IP: $name -> $addressStr");
            }
          }
        }
      }

      String? selectedIP = wifiIP;
      if (selectedIP == null || selectedIP == "0.0.0.0") {
        selectedIP = allValidIPs.firstWhere(
          (ip) => ip.startsWith('192.168.'),
          orElse: () => allValidIPs.isNotEmpty ? allValidIPs.first : '',
        );
        if (selectedIP.isEmpty) selectedIP = null;
      }

      if (selectedIP == null) {
        debugPrint("未能获取到任何有效的局域网网卡 IP");
        setState(() {
          _localIP = "未知IP";
        });
        return;
      }

      debugPrint("最终选择主 IP: $selectedIP (所有IP: $_localIPList)");

      setState(() {
        _localIP = selectedIP!;
      });

      // 绑定全网卡端口
      _udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _udpPort,
        reuseAddress: true,
      );
      _udpSocket?.broadcastEnabled = true;

      try {
        _udpSocket?.joinMulticast(InternetAddress('224.0.0.1'));
        debugPrint("强行加入组播组 224.0.0.1 成功");
      } catch (e) {
        debugPrint("加入组播组失败（非关键阻碍，继续执行）: $e");
      }

      _msgService.attachToExisting(_udpSocket!, _localIP);

      // 注册设备状态变更回调（心跳超时）
      _msgService.setDeviceStatusCallback((deviceId, status) {
        if (status == DeviceOnlineStatus.offline) {
          _onDeviceOffline(deviceId);
        }
      });

      _udpSocket?.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          Datagram? dg = _udpSocket?.receive();
          if (dg != null) {
            String rawData = utf8.decode(dg.data);
            debugPrint("【UDP原始层】收到 ${dg.data.length} 字节来自 ${dg.address.address}:${dg.port}");
            _handleIncomingBroadcast(rawData, dg.address.address);
            _msgService.handleRawData(rawData, dg.address.address);
          }
        }
      });

      _startAdvertising();
    } catch (e) {
      debugPrint("局域网初始化失败: $e");
    }
  }

  // 设备离线处理
  void _onDeviceOffline(String deviceId) {
    if (!mounted) return;
    setState(() {
      _onlineDeviceIds.remove(deviceId);
      final idx = _allDevices.indexWhere((d) => d.id == deviceId);
      if (idx != -1) {
        _allDevices[idx].onlineStatus = DeviceOnlineStatus.offline;
        _allDevices[idx].lastMsg = "设备已离线";
      }
    });
    _scheduleSaveDeviceList();
  }

  // 定时发送广播 + 组播
  void _startAdvertising() {
    _broadcastTimer?.cancel();
    _broadcastTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (_udpSocket == null || _localIP == "未知IP") return;

      Map<String, String> myInfo = {
        "id": _localIP,
        "name": _myDeviceName,
        "type": PlatformMobileExtension.isMobile ? "mobile" : "desktop",
        "cmd": "iamalive",
      };

      try {
        String jsonStr = jsonEncode(myInfo);
        List<int> dataToSend = utf8.encode(jsonStr);

        _udpSocket?.send(
          dataToSend,
          InternetAddress('255.255.255.255'),
          _udpPort,
        );

        _udpSocket?.send(dataToSend, InternetAddress('224.0.0.1'), _udpPort);
      } catch (e) {
        debugPrint("发送心跳失败: $e");
      }
    });
  }

  // 处理接收逻辑
  void _handleIncomingBroadcast(String rawData, String senderIP) {
    if (_localIPList.contains(senderIP)) {
      return;
    }

    try {
      dynamic decodedData = jsonDecode(rawData);
      if (decodedData is String) {
        decodedData = jsonDecode(decodedData);
      }
      if (decodedData is! Map) return;

      Map<String, dynamic> deviceData = Map<String, dynamic>.from(decodedData);
      String cmd = deviceData['cmd'] ?? '';

      if (cmd == 'iamalive' || cmd == 'i_see_you') {
        String id = deviceData['id'] ?? senderIP;
        if (_localIPList.contains(id)) return;

        String name = deviceData['name'] ?? "未知设备";
        String type = deviceData['type'] ?? "mobile";

        // 记录心跳
        _msgService.recordHeartbeat(id);

        // 桌面端对手机端进行单播响应
        if (cmd == 'iamalive' &&
            !PlatformMobileExtension.isMobile &&
            type == 'mobile') {
          _sendDirectReply(senderIP);
        }

        setState(() {
          _onlineDeviceIds.add(id);
          final existingIndex = _allDevices.indexWhere((d) => d.id == id);
          if (existingIndex != -1) {
            _allDevices[existingIndex].name = name;
            _allDevices[existingIndex].type = type;
            _allDevices[existingIndex].onlineStatus = DeviceOnlineStatus.online;
            _allDevices[existingIndex].lastSeen = DateTime.now();
            _allDevices[existingIndex].lastMsg =
                cmd == 'i_see_you' ? "已通过单播握手成功" : "在线";
          } else {
            _allDevices.add(_DeviceInfo(
              id: id,
              name: name,
              type: type,
              lastMsg: cmd == 'i_see_you' ? "已通过单播握手成功" : "刚刚上线",
              onlineStatus: DeviceOnlineStatus.online,
            ));
            debugPrint("🎉 成功跨端上线设备: $name ($id)");
          }
        });
        _scheduleSaveDeviceList();
      }
    } catch (e) {
      debugPrint("协议数据解析出现坏损丢弃: $e");
    }
  }

  // 精准单播应答函数
  void _sendDirectReply(String targetIP) {
    Map<String, String> replyInfo = {
      "id": _localIP,
      "name": _myDeviceName,
      "type": PlatformMobileExtension.isMobile ? "mobile" : "desktop",
      "cmd": "i_see_you",
    };

    try {
      List<int> replyData = utf8.encode(jsonEncode(replyInfo));
      _udpSocket?.send(replyData, InternetAddress(targetIP), _udpPort);
      debugPrint("⚡ 触发单播握手：已成功向目标 $targetIP 发送定向应答包");
    } catch (e) {
      debugPrint("单播应答包投递异常: $e");
    }
  }

  void _refreshDevices() {
    // 不清除 _allDevices，保留缓存设备（仅清除在线状态，重新扫描会更新）
    setState(() {
      _onlineDeviceIds.clear();
      // 将所有设备标记为 unknown，等扫描到后再更新为 online
      for (final d in _allDevices) {
        d.onlineStatus = DeviceOnlineStatus.unknown;
        d.lastMsg = '正在扫描...';
      }
    });
    _initLanDiscovery();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('正在重新扫描局域网...'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  // 清除所有聊天记录
  Future<void> _clearAllChatHistory() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除聊天记录'),
        content: const Text('确定要清除所有设备的聊天记录吗？\n\n此操作不会删除设备记录，仅清空聊天消息缓存。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('确定清除'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await _cacheService.clearAllMessages();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('所有聊天记录已清除'),
              duration: Duration(seconds: 1),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('清除失败: $e')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [_buildMessageTab(), _buildSettingTab()],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        type: BottomNavigationBarType.fixed,
        backgroundColor: const Color(0xFFF7F7F7),
        selectedItemColor: const Color(0xFF07C160),
        unselectedItemColor: Colors.black87,
        selectedFontSize: 10.5,
        unselectedFontSize: 10.5,
        items: [
          BottomNavigationBarItem(
            icon: Icon(
              _currentIndex == 0
                  ? Icons.chat_bubble
                  : Icons.chat_bubble_outline,
            ),
            label: '消息',
          ),
          BottomNavigationBarItem(
            icon: Icon(
              _currentIndex == 1 ? Icons.settings : Icons.settings_outlined,
            ),
            label: '设置',
          ),
        ],
      ),
    );
  }

  // ================= 消息 Tab 页（美化后的设备列表） =================
  Widget _buildMessageTab() {
    // 排序：在线设备在前，按名字排序
    final sortedDevices = List<_DeviceInfo>.from(_allDevices);
    sortedDevices.sort((a, b) {
      final aOnline = _onlineDeviceIds.contains(a.id);
      final bOnline = _onlineDeviceIds.contains(b.id);
      if (aOnline && !bOnline) return -1;
      if (!aOnline && bOnline) return 1;
      return a.name.compareTo(b.name);
    });

    return Scaffold(
      backgroundColor: const Color(0xFFEDF0F3),
      appBar: AppBar(
        title: const Text('局域网传输'),
        centerTitle: true,
        backgroundColor: const Color(0xFFF3F3F3),
        elevation: 0.5,
        titleTextStyle: const TextStyle(
          color: Colors.black87,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.black87),
            onPressed: _refreshDevices,
          ),
        ],
      ),
      body: sortedDevices.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CupertinoActivityIndicator(radius: 12),
                  const SizedBox(height: 12),
                  Text(
                    '正在搜索局域网设备...',
                    style: TextStyle(color: Colors.grey[600], fontSize: 14),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '本机IP: $_localIP',
                    style: TextStyle(color: Colors.grey[400], fontSize: 12),
                  ),
                ],
              ),
            )
          : ListView.separated(
              itemCount: sortedDevices.length,
              separatorBuilder: (context, index) => const Divider(
                height: 1,
                thickness: 0.5,
                indent: 74,
                color: Color(0xFFE5E5E5),
              ),
              itemBuilder: (context, index) {
                final device = sortedDevices[index];
                final isOnline = _onlineDeviceIds.contains(device.id);

                return _buildDeviceItem(device, isOnline);
              },
            ),
    );
  }

  Widget _buildDeviceItem(_DeviceInfo device, bool isOnline) {
    IconData deviceIcon;
    Color iconBgColor;
    Color iconColor;

    if (device.type == 'mobile') {
      deviceIcon = Icons.phone_android;
      iconBgColor = isOnline ? const Color(0xFFE8F5E9) : const Color(0xFFF5F5F5);
      iconColor = isOnline ? const Color(0xFF07C160) : Colors.grey;
    } else {
      deviceIcon = Icons.computer;
      iconBgColor = isOnline ? const Color(0xFFE3F2FD) : const Color(0xFFF5F5F5);
      iconColor = isOnline ? const Color(0xFF1976D2) : Colors.grey;
    }

    return InkWell(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ChatPage(
              id: device.id,
              title: device.name,
              msgService: _msgService,
              myDeviceName: _myDeviceName,
            ),
          ),
        );
      },
      child: Container(
        color: isOnline ? const Color(0xFFF9FFF9) : Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            // 头像区域 - 带在线状态指示
            Stack(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: iconBgColor,
                    borderRadius: BorderRadius.circular(12),
                    border: isOnline
                        ? Border.all(
                            color: const Color(0xFF07C160).withValues(alpha: 0.3),
                            width: 1.5)
                        : null,
                  ),
                  child: Icon(deviceIcon, color: iconColor, size: 24),
                ),
                if (isOnline)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: const BoxDecoration(
                        color: Color(0xFF07C160),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.check, size: 10, color: Colors.white),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          device.name,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: isOnline ? FontWeight.w600 : FontWeight.w500,
                            color: isOnline ? Colors.black87 : Colors.black54,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isOnline)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF07C160).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            '在线',
                            style: TextStyle(
                              fontSize: 10,
                              color: Color(0xFF07C160),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        )
                      else
                        Text(
                          _formatLastSeen(device.lastSeen),
                          style: TextStyle(fontSize: 11, color: Colors.grey[400]),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Text(
                        device.id,
                        style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                      ),
                      const Spacer(),
                      Text(
                        device.lastMsg,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: isOnline ? Colors.grey[600] : Colors.grey[400],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatLastSeen(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    return '${dt.month}/${dt.day}';
  }

  // ================= 设置 Tab 页 =================
  Widget _buildSettingTab() {
    return Scaffold(
      backgroundColor: const Color(0xFFEDF0F3),
      appBar: AppBar(
        title: const Text('设置'),
        centerTitle: true,
        backgroundColor: const Color(0xFFF3F3F3),
        elevation: 0.5,
        titleTextStyle: const TextStyle(
          color: Colors.black87,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
              color: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              child: Row(
                children: [
                  Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      color: const Color(0xFF07C160),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.person,
                      color: Colors.white,
                      size: 36,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _myDeviceName,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '本机局域网IP: $_localIP',
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // 清除聊天记录（替代原"清空所有传输历史"）
            GestureDetector(
              onTap: _clearAllChatHistory,
              child: _buildSettingCell(
                '清除所有聊天记录',
                textColor: Colors.redAccent,
                showArrow: false,
              ),
            ),
            const Divider(
              height: 0.5,
              thickness: 0.5,
              indent: 16,
              color: Color(0xFFE5E5E5),
            ),
            _buildSettingCell('关于局域网快传 v1.0'),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingCell(
    String title, {
    String? value,
    bool isSwitch = false,
    bool switchValue = false,
    Color textColor = Colors.black87,
    bool showArrow = true,
  }) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: TextStyle(fontSize: 16, color: textColor)),
          if (isSwitch)
            CupertinoSwitch(
              value: switchValue,
              onChanged: (v) {},
              activeTrackColor: const Color(0xFF07C160),
            )
          else
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (value != null)
                    Expanded(
                      child: Text(
                        value,
                        textAlign: TextAlign.end,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  if (showArrow) ...[
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.arrow_forward_ios,
                      size: 14,
                      color: Colors.grey,
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}
