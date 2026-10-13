// E1：发现/广播机器（socket 生命周期 + 广播目标 + 单播选栈）。
// 从 ChatListPage 抽出；visibility/deviceId 等宿主状态由调用方在广播前构造 payload，
// 收包回调 onDatagram 注入（v4/v6 共用同一 handler，消除原实现两份重复监听）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:wechat_lan_transfer/Services/lan_utils.dart';
import 'package:wechat_lan_transfer/Services/udp_message_service.dart';
import 'package:wechat_lan_transfer/Services/udp_port_probe.dart';

class LanDiscoveryService {
  LanDiscoveryService();

  RawDatagramSocket? _udpSocket;
  RawDatagramSocket? _udpSocketV6;
  int _udpPort = UdpMessageService.defaultMsgPort;
  bool _started = false;

  /// 本端实际绑定的 UDP 端口（探测回退后可能不是首选）。
  int get udpPort => _udpPort;

  /// 与 UdpMessageService attachToExisting 共用的 v4 socket。
  RawDatagramSocket? get socket => _udpSocket;

  bool get isReady => _started && _udpSocket != null;

  /// 绑定：首选端口探测回退（v4 先试，失败回退 anyIPv6）+ 组播 224.0.0.1 +
  /// v6（本机有 v6 私有地址才绑，同端口，加入 ff02::1）。
  /// [onDatagram] 收包回调（v4/v6 共用，宿主做发现 + 消息处理）。
  /// 绑定失败抛错由调用方处理。
  Future<void> start({
    required int preferredPort,
    required List<String> localIPs,
    required void Function(String rawData, String senderIp, int srcPort)
    onDatagram,
  }) async {
    _udpSocket = await _bindWithProbe(preferredPort);
    _udpPort = _udpSocket!.port;
    _udpSocket?.broadcastEnabled = true;
    try {
      _udpSocket?.joinMulticast(InternetAddress('224.0.0.1'));
      debugPrint('[Discovery] 强行加入组播组 224.0.0.1 成功');
    } catch (e) {
      debugPrint('[Discovery] 加入组播组失败（非关键阻碍，继续执行）: $e');
    }
    _udpSocketV6 = await _bindV6(_udpPort, localIPs);
    _listen(_udpSocket!, onDatagram);
    final v6 = _udpSocketV6;
    if (v6 != null) {
      _listen(v6, onDatagram);
    }
    _started = true;
    debugPrint('[Discovery] 发现 socket 已就绪: v4=$_udpPort v6=${v6?.port}');
  }

  /// 广播一份 payload 到全部目标端口：255.255.255.255（同子网）+
  /// 224.0.0.1（组播）+ 各子网广播地址（跨子网）+ ff02::1（v6 链路本地）。
  /// [ports] 为目标端口集合（announce_payload.announceTargetPorts 生成：
  /// 默认端口探测范围 ∪ 本端端口），覆盖对端绑定回退。
  void broadcast(
    List<int> data,
    List<int> ports,
    List<InternetAddress> subnetBroadcasts,
  ) {
    try {
      for (final port in ports) {
        _udpSocket?.send(data, InternetAddress('255.255.255.255'), port);
        _udpSocket?.send(data, InternetAddress('224.0.0.1'), port);
        for (final addr in subnetBroadcasts) {
          _udpSocket?.send(data, addr, port);
        }
        _udpSocketV6?.send(data, InternetAddress('ff02::1'), port);
      }
    } catch (e) {
      debugPrint('发送广播失败: $e');
    }
  }

  /// 单播发送（N2：v6 目标走 v6 socket，无 v6 socket 时回退 v4，旧行为不变）。
  /// socket 未就绪/发送失败返回 false（调用方提示检查对端端口）。
  bool sendTo(List<int> data, String targetIp, int port) {
    final sock = (targetIp.contains(':') && _udpSocketV6 != null)
        ? _udpSocketV6
        : _udpSocket;
    if (sock == null) return false;
    try {
      sock.send(Uint8List.fromList(data), InternetAddress(targetIp), port);
      return true;
    } catch (e) {
      debugPrint('单播投递异常: $e');
      return false;
    }
  }

  /// 安全关闭并释放 socket（v4 + v6）。
  void stop() {
    try {
      _udpSocket?.close();
      _udpSocketV6?.close();
    } catch (e) {
      debugPrint("释放 UDP Socket 异常: $e");
    } finally {
      _udpSocket = null;
      _udpSocketV6 = null;
      _started = false;
    }
  }

  /// P1-1：从首选端口起连续探测（E1：高阶纯函数抽至 udp_port_probe）。
  Future<RawDatagramSocket> _bindWithProbe(int preferred) {
    return probeUdpPort<RawDatagramSocket>(
      preferred,
      (addr, port) => RawDatagramSocket.bind(addr, port, reuseAddress: true),
      log: (m) => debugPrint('[Discovery] P1-1/P1-N2 $m'),
    );
  }

  /// N2：本机有 IPv6 私有地址才返回绑定的 v6 socket（与 v4 同端口），
  /// 失败只打日志返回 null（发现降级为纯 v4）。
  Future<RawDatagramSocket?> _bindV6(int port, List<String> localIPs) async {
    final hasV6 = localIPs.any((ip) => LanUtils.isPrivateIPv6(ip));
    if (!hasV6) return null;
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv6,
        port,
        reuseAddress: true,
      );
      try {
        socket.joinMulticast(InternetAddress('ff02::1'));
        debugPrint('[Discovery] N2 已加入 IPv6 组播 ff02::1');
      } catch (e) {
        debugPrint('[Discovery] N2 加入 IPv6 组播失败（继续单播/广播）: $e');
      }
      debugPrint('[Discovery] N2 IPv6 socket 绑定成功: $port');
      return socket;
    } catch (e) {
      debugPrint('[Discovery] N2 IPv6 socket 绑定失败，降级纯 v4: $e');
      return null;
    }
  }

  /// v4/v6 共用收包 handler（E1：消除原实现两份重复监听回调）。
  void _listen(
    RawDatagramSocket socket,
    void Function(String rawData, String senderIp, int srcPort) onDatagram,
  ) {
    socket.listen((RawSocketEvent event) {
      if (event != RawSocketEvent.read) return;
      final dg = socket.receive();
      if (dg == null) return;
      final rawData = utf8.decode(dg.data);
      debugPrint(
        '【UDP原始层】收到 ${dg.data.length} 字节来自 ${dg.address.address}:${dg.port}',
      );
      onDatagram(rawData, dg.address.address, dg.port);
    });
  }
}
