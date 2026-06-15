import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:device_info_plus/device_info_plus.dart'; // 💡 引入真实设备信息库
import 'chat_page.dart';

// 利用 Extension 扩展 Platform，优雅地补充 isMobile 属性
extension PlatformMobileExtension on Platform {
  static bool get isMobile => Platform.isAndroid || Platform.isIOS;
}

class ChatListPage extends StatefulWidget {
  const ChatListPage({super.key});

  @override
  ChatListPageState createState() => ChatListPageState();
}

class ChatListPageState extends State<ChatListPage> {
  int _currentIndex = 0;

  // 真正的在线设备动态列表
  final List<Map<String, String>> _realLanDevices = [];

  // UDP 局域网通讯配置
  static const int _udpPort = 8888;
  RawDatagramSocket? _udpSocket;
  Timer? _broadcastTimer;
  String _localIP = "未知IP";
  String _myDeviceName = "加载中...";

  // 存储本机的所有合法 IPv4，用于精准防自锁
  final List<String> _localIPList = [];

  @override
  void initState() {
    super.initState();
    _initDeviceAndNetwork();
  }

  @override
  void dispose() {
    _broadcastTimer?.cancel();
    _closeUdpSocket(); // 确保安全释放旧的 Socket
    super.dispose();
  }

  // 安全关闭并释放旧 Socket 的方法，防止端口残留导致重新扫描时卡死
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
    await _fetchRealDeviceName(); // 1. 先把真实的设备名字抠出来
    await _initLanDiscovery(); // 2. 再启动网络引擎
  }

  // 💡 核心改动：动态获取真实设备名称
  Future<void> _fetchRealDeviceName() async {
    final deviceInfo = DeviceInfoPlugin();
    String detectedName = "未知设备";

    try {
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        // 优先获取用户对手机的命名（生产厂商+营销型号，如 "Xiaomi 14"）
        detectedName = "${androidInfo.manufacturer} ${androidInfo.model}";
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        // iOS 可以直接拿到用户在系统设置里改的个性化名字（如 "张三的 iPhone"）
        detectedName = iosInfo.name;
      } else if (Platform.isWindows) {
        final windowsInfo = await deviceInfo.windowsInfo;
        // 获取 Windows 的计算机全名（如 "DESKTOP-PC"）
        detectedName = windowsInfo.computerName;
      } else if (Platform.isMacOS) {
        final macosInfo = await deviceInfo.macOsInfo;
        // 获取 Mac 的计算机名（如 "MacBook Pro"）
        detectedName = macosInfo.computerName;
      } else if (Platform.isLinux) {
        final linuxInfo = await deviceInfo.linuxInfo;
        detectedName = linuxInfo.name;
      }
    } catch (e) {
      debugPrint("读取硬件设备名失败，降级处理: $e");
      // 兜底降级方案
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
      String? ip;
      _localIPList.clear();

      // 1. 优先尝试通过网络库获取 Wi-Fi IP
      try {
        final info = NetworkInfo();
        ip = await info.getWifiIP();
        if (ip != null && ip != "0.0.0.0") {
          _localIPList.add(ip);
        }
      } catch (_) {}

      // 2. 遍历底层所有物理网卡，排除虚拟网卡干扰
      List<NetworkInterface> interfaces = await NetworkInterface.list(
        includeLoopback: false, // 排除本地回环 127.0.0.1
        type: InternetAddressType.IPv4, // 只找有线或无线的 IPv4 地址
      );

      for (var interface in interfaces) {
        String name = interface.name.toLowerCase();
        if (name.contains('virtual') ||
            name.contains('vbox') ||
            name.contains('vmnet') ||
            name.contains('wsl') ||
            name.contains('vethernet')) {
          continue;
        }

        for (var addr in interface.addresses) {
          String addressStr = addr.address;
          if (addressStr.startsWith('192.168.') ||
              addressStr.startsWith('10.') ||
              addressStr.startsWith('172.')) {
            if (!_localIPList.contains(addressStr)) {
              _localIPList.add(addressStr);
            }
            if (ip == null || ip == "0.0.0.0") {
              ip = addressStr; // 挑选第一个作为展示用的主 IP
            }
          }
        }
      }

      if (ip == null) {
        debugPrint("未能获取到任何有效的局域网网卡 IP");
        setState(() {
          _localIP = "未知IP";
        });
        return;
      }

      setState(() {
        _localIP = ip!;
      });

      // 绑定全网卡端口，开启复用
      _udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _udpPort,
        reuseAddress: true,
      );
      _udpSocket?.broadcastEnabled = true;

      // 强行加入固定组播组 224.0.0.1，防范 Android 硬件级广播锁
      try {
        _udpSocket?.joinMulticast(InternetAddress('224.0.0.1'));
        debugPrint("强行加入组播组 224.0.0.1 成功");
      } catch (e) {
        debugPrint("加入组播组失败（非关键阻碍，继续执行）: $e");
      }

      // 监听接收函数
      _udpSocket?.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          Datagram? dg = _udpSocket?.receive();
          if (dg != null) {
            String rawData = utf8.decode(dg.data);
            _handleIncomingBroadcast(rawData, dg.address.address);
          }
        }
      });

      _startAdvertising();
    } catch (e) {
      debugPrint("局域网初始化失败: $e");
    }
  }

  // 定时发送广播 + 组播
  void _startAdvertising() {
    _broadcastTimer?.cancel();
    _broadcastTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (_udpSocket == null || _localIP == "未知IP") return;

      Map<String, String> myInfo = {
        "id": _localIP,
        "name": _myDeviceName, // 这里发送的是上面动态抠出来的真实设备名
        "type": PlatformMobileExtension.isMobile ? "mobile" : "desktop",
        "cmd": "iamalive",
      };

      try {
        String jsonStr = jsonEncode(myInfo);
        List<int> dataToSend = utf8.encode(jsonStr);

        // 1. 发送标准全网广播（覆盖桌面端、部分宽松的移动端）
        _udpSocket?.send(
          dataToSend,
          InternetAddress('255.255.255.255'),
          _udpPort,
        );

        // 2. 追加发送通用组播（穿透手机端广播屏蔽锁）
        _udpSocket?.send(dataToSend, InternetAddress('224.0.0.1'), _udpPort);
      } catch (e) {
        debugPrint("发送心跳失败: $e");
      }
    });
  }

  // 处理接收逻辑：支持 iamalive（盲发心跳） 和 i_see_you（单播定向回传应答）
  void _handleIncomingBroadcast(String rawData, String senderIP) {
    debugPrint("【网络层拦截】收到来自 $senderIP 的原始包 -> $rawData");

    // 防回路自激拦截
    if (_localIPList.contains(senderIP)) return;

    try {
      dynamic decodedData = jsonDecode(rawData);
      if (decodedData is String) {
        decodedData = jsonDecode(decodedData);
      }
      if (decodedData is! Map) return;

      Map<String, dynamic> deviceData = Map<String, dynamic>.from(decodedData);
      String cmd = deviceData['cmd'] ?? '';

      // 支持普通心跳包与精准单播响应包
      if (cmd == 'iamalive' || cmd == 'i_see_you') {
        String id = deviceData['id'] ?? senderIP;
        if (_localIPList.contains(id)) return;

        String name = deviceData['name'] ?? "未知设备";
        String type = deviceData['type'] ?? "mobile";

        // 💡 核心机制：如果 Windows 电脑发现了手机的心跳，立刻对手机的 IP 进行点名“单播响应”
        // 这一步能彻底斩断由于路由器 AP 隔离或 Android 限制导致的单向失联
        if (cmd == 'iamalive' &&
            !PlatformMobileExtension.isMobile &&
            type == 'mobile') {
          _sendDirectReply(senderIP);
        }

        int existingIndex = _realLanDevices.indexWhere(
          (element) => element['id'] == id,
        );

        setState(() {
          if (existingIndex != -1) {
            _realLanDevices[existingIndex]['name'] = name;
            _realLanDevices[existingIndex]['lastMsg'] = "在线 (已同步)";
          } else {
            _realLanDevices.add({
              "id": id,
              "name": name,
              "type": type,
              "lastMsg": cmd == 'i_see_you' ? "已通过单播握手成功" : "刚刚上线，点击开始传输",
            });
            debugPrint("🎉 成功跨端上线设备: $name ($id)");
          }
        });
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
      "cmd": "i_see_you", // 声明这是定向回应包
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
    setState(() {
      _realLanDevices.clear();
    });
    _initDeviceAndNetwork();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('正在重新初始化并扫描局域网...'),
        duration: Duration(seconds: 1),
      ),
    );
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

  // ================= 消息 Tab 页（真实设备列表） =================
  Widget _buildMessageTab() {
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
      body: _realLanDevices.isEmpty
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
              itemCount: _realLanDevices.length,
              separatorBuilder: (context, index) => const Divider(
                height: 1,
                thickness: 0.5,
                indent: 74,
                color: Color(0xFFE5E5E5),
              ),
              itemBuilder: (context, index) {
                final device = _realLanDevices[index];
                IconData deviceIcon = Icons.devices;
                if (device['type'] == 'mobile') {
                  deviceIcon = Icons.phone_android;
                }
                if (device['type'] == 'desktop') deviceIcon = Icons.computer;

                return InkWell(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            ChatPage(id: device['id']!, title: device['name']!),
                      ),
                    );
                  },
                  child: Container(
                    color: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: const Color(0xFFE1E1E1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Icon(
                            deviceIcon,
                            color: Colors.black54,
                            size: 26,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    device['name']!,
                                    style: const TextStyle(
                                      fontSize: 16.5,
                                      fontWeight: FontWeight.w500,
                                      color: Colors.black,
                                    ),
                                  ),
                                  Text(
                                    device['id']!,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey[500],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 5),
                              Text(
                                device['lastMsg']!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13.5,
                                  color: Colors.grey[600],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
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
            _buildSettingCell('传输保存路径', value: '/storage/emulated/0/Download'),
            const Divider(
              height: 0.5,
              thickness: 0.5,
              indent: 16,
              color: Color(0xFFE5E5E5),
            ),
            _buildSettingCell('自动接收小文件', isSwitch: true, switchValue: true),
            const SizedBox(height: 12),
            _buildSettingCell('清空所有传输历史', textColor: Colors.redAccent),
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
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.arrow_forward_ios,
                    size: 14,
                    color: Colors.grey,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
