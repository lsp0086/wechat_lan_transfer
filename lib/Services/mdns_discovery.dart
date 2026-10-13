import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:multicast_dns/multicast_dns.dart';

/// P1-N1：mDNS 发现封装。
/// 查询：multicast_dns One-Shot Query（PTR/SRV）。
/// 发布：N1 已接原生 NSD/Bonjour——Android NsdManager / iOS NSNetService，
/// 经 MethodChannel('wechat_lan_transfer/mdns') 发布 `_wlt._tcp` 服务；
/// 桌面端无原生实现，静默降级为 no-op（发现仍走 UDP 广播）。
class MdnsDiscovery {
  /// 与 iOS NSBonjourServices / Android 查询保持一致的服务类型。
  static const String serviceType = '_wlt._tcp.local';
  static const String udpServiceType = '_wlt._udp.local';

  static const MethodChannel _channel = MethodChannel(
    'wechat_lan_transfer/mdns',
  );

  MDnsClient? _client;
  bool _running = false;
  bool _published = false;

  bool get isRunning => _running;

  /// 启动 mDNS client（查询监听；发布走 [publishAnnounce]）。
  Future<void> startAnnounce() async {
    if (_running) return;
    try {
      final client = MDnsClient();
      await client.start();
      _client = client;
      _running = true;
      debugPrint('[MdnsDiscovery] mDNS client 已启动（查询监听）');
    } catch (e) {
      debugPrint('[MdnsDiscovery] mDNS 启动失败（忽略）: $e');
    }
  }

  /// N1：发布 `_wlt._tcp` 服务（Android NSD / iOS Bonjour）。
  /// TXT 携带 deviceId/udpPort，消费端按其定位身份与 UDP 端口。
  /// 通道不可用/平台不支持时静默降级，不阻塞发现。
  Future<void> publishAnnounce({
    required String name,
    required int port,
    String deviceId = '',
    int? udpPort,
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    if (_published) return;
    try {
      final out = await _channel.invokeMethod<String>('register', {
        'name': name,
        'port': port,
        'deviceId': deviceId,
        'udpPort': udpPort,
      });
      _published = true;
      debugPrint('[MdnsDiscovery] N1 已发布 mDNS 服务: ${out ?? name}:$port');
    } catch (e) {
      debugPrint('[MdnsDiscovery] N1 mDNS 发布失败（忽略）: $e');
    }
  }

  /// N1：撤销 mDNS 发布（退出/重启发现时调用）。
  Future<void> unpublish() async {
    if (!_published) return;
    _published = false;
    try {
      await _channel.invokeMethod('unregister');
    } catch (_) {}
  }

  /// 查询局域网内 `_wlt._tcp.local` PTR 记录（失败返回空流，只打日志）。
  Stream<PtrResourceRecord> discover({
    String service = serviceType,
    Duration timeout = const Duration(seconds: 5),
  }) {
    final client = _client;
    if (client == null || !_running) {
      debugPrint('[MdnsDiscovery] client 未启动，跳过查询');
      return const Stream.empty();
    }
    try {
      return client.lookup<PtrResourceRecord>(
        ResourceRecordQuery.serverPointer(service),
        timeout: timeout,
      );
    } catch (e) {
      debugPrint('[MdnsDiscovery] mDNS 查询失败（忽略）: $e');
      return const Stream.empty();
    }
  }

  /// N1：完整 mDNS 兜底发现：PTR → SRV(端口) → A/AAAA(IP) → TXT(身份)。
  /// 返回类型化设备列表（按实例名去重）；失败返回空列表，只打日志。
  /// 作为 UDP 广播被吞（AP 隔离/部分路由器）时的兜底发现通道。
  Future<List<MdnsDevice>> discoverDevices({
    String service = serviceType,
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final client = _client;
    if (client == null || !_running) return const [];
    try {
      final ptrs = await client
          .lookup<PtrResourceRecord>(
            ResourceRecordQuery.serverPointer(service),
            timeout: timeout,
          )
          .toList();
      final out = <MdnsDevice>[];
      final seenNames = <String>{};
      for (final ptr in ptrs) {
        final domain = ptr.domainName;
        if (!seenNames.add(domain)) continue;
        // SRV：目标主机 + TCP 端口
        SrvResourceRecord? srv;
        try {
          srv = await client
              .lookup<SrvResourceRecord>(
                ResourceRecordQuery.service(domain),
                timeout: timeout,
              )
              .first;
        } catch (_) {}
        if (srv == null) continue;
        // A/AAAA：目标 IP（先 v4，无则 v6）
        IPAddressResourceRecord? addrRec;
        try {
          addrRec = await client
              .lookup<IPAddressResourceRecord>(
                ResourceRecordQuery.addressIPv4(srv.target),
                timeout: timeout,
              )
              .first;
        } catch (_) {}
        if (addrRec == null) {
          try {
            addrRec = await client
                .lookup<IPAddressResourceRecord>(
                  ResourceRecordQuery.addressIPv6(srv.target),
                  timeout: timeout,
                )
                .first;
          } catch (_) {}
        }
        if (addrRec == null) continue;
        // TXT：name/deviceId/udpPort（旧 announce 无 TXT 时按缺省）
        TxtResourceRecord? txtRec;
        try {
          txtRec = await client
              .lookup<TxtResourceRecord>(
                ResourceRecordQuery.text(domain),
                timeout: timeout,
              )
              .first;
        } catch (_) {}
        final parsed = parseMdnsTxt(txtRec?.text);
        final instanceLabel = domain.split('.').first;
        out.add(
          MdnsDevice(
            name: parsed.name.isNotEmpty ? parsed.name : instanceLabel,
            ip: addrRec.address.address,
            port: srv.port,
            deviceId: parsed.deviceId,
            udpPort: parsed.udpPort,
          ),
        );
      }
      return out;
    } catch (e) {
      debugPrint('[MdnsDiscovery] N1 mDNS 兜底发现失败（忽略）: $e');
      return const [];
    }
  }

  /// 停止并释放 mDNS client。
  void stop() {
    unpublish();
    try {
      _client?.stop();
    } catch (e) {
      debugPrint('[MdnsDiscovery] mDNS 停止异常（忽略）: $e');
    } finally {
      _client = null;
      _running = false;
    }
  }
}

/// N1：mDNS 兜底发现结果（类型化，对标 localsend-rs）。
class MdnsDevice {
  final String name;
  final String ip;
  /// SRV 端口（= 对端 TCP 文件端口）。
  final int port;
  /// TXT 携带的持久身份键（旧 announce 无 TXT 时为空串，回退 IP 键）。
  final String deviceId;
  /// TXT 携带的对端 UDP 端口（缺省 null，消费端回退默认端口）。
  final int? udpPort;

  const MdnsDevice({
    required this.name,
    required this.ip,
    required this.port,
    required this.deviceId,
    required this.udpPort,
  });
}

/// N1：TXT 解析（纯函数，可单测）。multicast_dns 把 length-prefixed TXT 串
/// 以换行拼接（key=value 每行一条，来自 NSD setAttribute / Bonjour TXT）。
({String name, String deviceId, int? udpPort}) parseMdnsTxt(String? raw) {
  if (raw == null || raw.isEmpty) {
    return (name: '', deviceId: '', udpPort: null);
  }
  String? name;
  String? deviceId;
  int? udpPort;
  for (final line in raw.split('\n')) {
    final l = line.trim();
    if (l.startsWith('name=')) {
      name = l.substring('name='.length);
    } else if (l.startsWith('deviceId=')) {
      deviceId = l.substring('deviceId='.length);
    } else if (l.startsWith('udpPort=')) {
      udpPort = int.tryParse(l.substring('udpPort='.length));
    }
  }
  return (name: name ?? '', deviceId: deviceId ?? '', udpPort: udpPort);
}
