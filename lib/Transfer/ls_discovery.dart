// LocalSend Protocol v2 组播发现。
// 对齐官方 packages/core/src/discovery/mod.rs + multicast/mod.rs：
// - 组播组 224.0.0.167:53317（官方 DEFAULT_MULTICAST_GROUP，仅 224.0.0.0/24
//   内的组地址在部分 Android 设备可收，故不可换）；announce 载荷 = 设备信息
//   JSON + 遗留 announce:true 标志（官方 AnnouncedMessage）
// - 发现不经 UDP 回包：对新指纹 POST /api/localsend/v2/register 确认在线，
//   同时把本端登记到对端（官方 probe 语义）；register 尽力而为，
//   不阻塞设备展示（announce 本身即存活证明，安全由传输期钉扎+PIN 保证）
// - iOS 无组播 entitlement 时组播/受限广播收发全被系统拦截（errno 65），
//   反向发现依赖服务端 register 回调（noteRegisterPeer），并周期向已知对端
//   补发单播 announce 保活（单播不受 entitlement 限制）
// - Android 收组播需 MulticastLock（MethodChannel wechat_lan_transfer/multicast）
// - 启动突发 announce（100/500/2000ms，对齐官方 ANNOUNCE_DELAYS），随后 3s 周期

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:wechat_lan_transfer/Services/tls_identity_service.dart';
import 'package:wechat_lan_transfer/Transfer/ls_dto.dart';

/// v2 组播发现事件（每条有效 announce 一条；调用方按 fingerprint 合并/刷新在线）。
class LsDiscoveredDevice {
  final String fingerprint;
  final String alias;
  final String ip; // 数据报源地址（对端 HTTP 服务可达地址）
  final int port; // 对端 HTTPS 服务端口
  final String version;
  final String? deviceModel;
  final String? deviceType;
  final bool download;
  final DateTime lastSeen;

  const LsDiscoveredDevice({
    required this.fingerprint,
    required this.alias,
    required this.ip,
    required this.port,
    required this.version,
    this.deviceModel,
    this.deviceType,
    this.download = false,
    required this.lastSeen,
  });

  LsDiscoveredDevice copyWith({DateTime? lastSeen}) => LsDiscoveredDevice(
        fingerprint: fingerprint,
        alias: alias,
        ip: ip,
        port: port,
        version: version,
        deviceModel: deviceModel,
        deviceType: deviceType,
        download: download,
        lastSeen: lastSeen ?? this.lastSeen,
      );
}

/// 纯函数：解析 v2 组播 announce 载荷（官方 MulticastMessageV2，camelCase）。
/// 缺 fingerprint / 端口非法返回 null；alias 为空回退 '未知设备'。
LsDiscoveredDevice? lsParseAnnounce(Map<String, dynamic> json, String ip) {
  final fp = '${json['fingerprint'] ?? ''}'.trim().toLowerCase();
  if (fp.isEmpty) return null;
  final port = (json['port'] as num?)?.toInt() ?? kLsDefaultPort;
  if (port <= 0 || port > 65535) return null;
  return LsDiscoveredDevice(
    fingerprint: fp,
    alias: () {
      final a = '${json['alias'] ?? ''}'.trim();
      return a.isEmpty ? '未知设备' : a;
    }(),
    ip: ip,
    port: port,
    version: '${json['version'] ?? ''}',
    deviceModel: json['deviceModel'] as String?,
    deviceType: json['deviceType'] as String?,
    download: json['download'] == true,
    lastSeen: DateTime.now(),
  );
}

/// 纯函数：组装本端 announce 载荷（设备信息 + 遗留 announce 标志）。
Map<String, dynamic> lsBuildAnnounce(LsDeviceDto self) => {
      ...self.toJson(),
      'announce': true,
    };

/// v2 组播发现服务。一个进程一个实例即可。
class LsDiscovery {
  LsDiscovery._();
  static final LsDiscovery instance = LsDiscovery._();

  static const _multicastChannel = MethodChannel('wechat_lan_transfer/multicast');

  /// 单包上限：announce 远小于 64KB，超限直接丢弃（防解析浪费）。
  static const int maxDatagramBytes = 64 * 1024;

  /// 周期 announce 间隔。
  static const Duration announceInterval = Duration(seconds: 3);

  RawDatagramSocket? _socket;
  /// 独立发送 socket：RawDatagramSocket 的异步发送错误会终止其读事件流
  /// （实测 errno 49/65 后 socket 从此收不到任何数据报，release 端整个
  /// 发现失联），监听 socket 必须只收不发，announce 全部走它。
  RawDatagramSocket? _sendSocket;
  Timer? _announceTimer;
  bool _running = false;
  int _boundPort = kLsDefaultPort;
  int get boundPort => _boundPort;
  bool get isRunning => _running;

  /// 本端设备信息（alias/fingerprint/port=HTTPS 服务端口）。
  LsDeviceDto Function()? selfInfo;

  /// 额外广播目标（如各子网广播地址），与组播/255.255.255.255 一并发送。
  List<InternetAddress> extraBroadcastTargets = const [];

  final StreamController<LsDiscoveredDevice> _events =
      StreamController<LsDiscoveredDevice>.broadcast();

  Stream<LsDiscoveredDevice> get stream => _events.stream;

  /// 已发起过 register 的指纹（含进行中）-> 最近一次发起时间，
  /// 超过 [registerRetryInterval] 再重发（对端可能后启动错过首次）。
  final Map<String, DateTime> _registerAttempted = {};

  /// register 重发间隔。必须 < 心跳超时（UdpMsgService.heartbeatTimeout
  /// 10s）：某端 UDP 入站被系统拦截时（如 macOS 本地网络 TCC 静默丢弃
  /// 跨设备入站单播，实测 debug 版必现），对端只能靠本端周期 register
  /// 刷新在线状态，间隔过长会导致设备在列表上闪烁离线。
  static const Duration registerRetryInterval = Duration(seconds: 8);

  /// 已知对端（announce/register 学习到的 ip -> 对端发现 socket UDP 端口）。
  /// 周期 announce 时额外向这些对端补发单播，绕开 iOS 组播/广播限制保活。
  final Map<String, int> _knownPeers = {};

  /// 子网扫描（官方 scan_subnet 对等）：正在扫描的接口 IP（防重入）。
  final Set<String> _scanningIfaces = {};

  /// 自动扫描定时器：扫到设备或 stop() 时停止。
  Timer? _scanTimer;

  /// 本端 v4 IP 列表（调用方启动前注入，子网扫描用）。
  List<String> localV4Ips = const [];

  /// 启动（幂等）。绑定 UDP 53317（占用则向下兼容探测 +1..+10），
  /// 加入组播组并开始周期 announce。
  Future<void> start() async {
    if (_running) return;
    _running = true;

    // Android：组播锁先于 socket，保证首个 announce 突发即可被对端手机收到
    if (Platform.isAndroid) {
      try {
        await _multicastChannel.invokeMethod<void>('acquire');
      } catch (e) {
        debugPrint('[LsDiscovery] MulticastLock 获取失败（组播可能收不到）: $e');
      }
    }

    RawDatagramSocket? socket;
    Object? lastError;
    for (var port = kLsDefaultPort; port < kLsDefaultPort + 10; port++) {
      try {
        socket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          port,
          reuseAddress: true,
        );
        _boundPort = port;
        break;
      } on SocketException catch (e) {
        lastError = e;
      }
    }
    if (socket == null) {
      _running = false;
      throw Exception('v2 发现绑定 UDP 端口失败（$kLsDefaultPort..${kLsDefaultPort + 9}）: $lastError');
    }
    _socket = socket;
    final sock = socket;
    // 发送 255.255.255.255 / 子网广播地址必须显式开 SO_BROADCAST，
    // 否则 send 异步报 EACCES（errno 13），announce 广播全灭（组播不受影响）
    sock.broadcastEnabled = true;
    // iOS 无组播 entitlement：join 成功反而会把 socket 入站整体拦掉
    // （同 8888 教训），join 失败反而幸存；统一 iOS 跳过最稳
    if (Platform.isIOS) {
      debugPrint('[LsDiscovery] iOS 跳过加入组播组 $kLsMulticastAddr');
    } else {
      try {
        socket.joinMulticast(InternetAddress(kLsMulticastAddr));
      } catch (e) {
        debugPrint('[LsDiscovery] 加入组播组失败（仅广播发现可用）: $e');
      }
    }
    socket.listen((event) {
      if (event == RawSocketEvent.read) {
        final dg = sock.receive();
        if (dg != null) _handleDatagram(dg);
      }
    }, onError: (Object e) {
      debugPrint('[LsDiscovery] 监听异常: $e');
    });

    // 独立发送 socket（临时端口 + SO_BROADCAST），发送错误只打日志不毒化监听
    try {
      final sender = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      // 发送 255.255.255.255 / 子网广播地址必须显式开 SO_BROADCAST，
      // 否则 send 异步报 EACCES（errno 13）（组播不受影响）
      sender.broadcastEnabled = true;
      sender.listen((_) {}, onError: (Object e) {
        debugPrint('[LsDiscovery] 发送 socket 异常（忽略）: $e');
      });
      _sendSocket = sender;
    } catch (e) {
      debugPrint('[LsDiscovery] 发送 socket 创建失败（退化为监听 socket 发送）: $e');
    }

    // 启动突发：100/500/2000ms（对齐官方 ANNOUNCE_DELAYS）+ 周期 3s
    _announceAt(const Duration(milliseconds: 100));
    _announceAt(const Duration(milliseconds: 500));
    _announceAt(const Duration(milliseconds: 2000));
    _announceTimer = Timer.periodic(announceInterval, (_) => _announce());
    debugPrint('[LsDiscovery] v2 组播发现已启动: UDP 端口 $_boundPort');
    // 自动子网扫描：5s 后首扫（announce 突发已发完），空手而归则每 30s
    // 重扫直到发现设备。官方 scan_subnet 语义：组播不可用网络上的兜底
    _scanTimer = Timer(const Duration(seconds: 5), _autoScan);
  }

  /// 自动扫描：发现过设备（_knownPeers 非空）就不再扫，否则 30s 重试。
  Future<void> _autoScan() async {
    if (!_running) return;
    final found = await scanSubnet();
    if (found || !_running) return;
    _scanTimer = Timer(const Duration(seconds: 30), _autoScan);
  }

  /// 子网 HTTP 扫描（对齐官方 discovery scan_subnet）：对本端 v4 接口的
  /// /24 网段逐个 POST /register 探测（并发 50、单请求 700ms 兜底超时）。
  /// 无组播 entitlement/announce 被拦的网络上的兜底发现——HTTPS 走 TCP，
  /// 不受任何 UDP 拦截影响，对端 HTTPS 服务可达即被发现。
  /// 返回本次是否扫到至少一台对端。
  Future<bool> scanSubnet({String? interfaceIp}) async {
    final self = selfInfo?.call();
    if (!_running || self == null) return false;
    final v4s = localV4Ips
        .where((ip) => !ip.contains(':') && ip != '127.0.0.1')
        .toList();
    final localIp = interfaceIp ?? (v4s.isEmpty ? '' : v4s.first);
    if (localIp.isEmpty) return false;
    if (!_scanningIfaces.add(localIp)) return false;
    try {
      final octets = localIp.split('.');
      if (octets.length != 4) return false;
      final prefix = '${octets[0]}.${octets[1]}.${octets[2]}.';
      final selfFp = TlsIdentityService.instance.fingerprint.toLowerCase();
      final declaredFp = self.fingerprint.trim().toLowerCase();
      final targets = <String>[];
      for (var h = 1; h < 255; h++) {
        final ip = '$prefix$h';
        if (ip == localIp) continue;
        targets.add(ip);
      }
      debugPrint('[LsDiscovery] 子网扫描开始: ${prefix}0/24 (${targets.length} 个目标)');
      var found = 0;
      // 分批并发（官方 SCAN_CONCURRENCY=50）；跳过 .0/.255 减少无效超时
      for (var i = 0; i < targets.length; i += 50) {
        final batch = targets.skip(i).take(50);
        await Future.wait(batch.map((ip) async {
          final device = await _probe(ip, self.port, selfFp, declaredFp);
          if (device != null) {
            found++;
            _knownPeers.putIfAbsent(ip, () => kLsDefaultPort);
            _events.add(device);
          }
        }));
      }
      debugPrint('[LsDiscovery] 子网扫描完成: 发现 $found 台设备');
      return found > 0;
    } finally {
      _scanningIfaces.remove(localIp);
    }
  }

  /// 向 host:port 发 register 探测。对端自签证书一律接受（TOFU，传输期
  /// 钉扎+PIN 保证安全），指纹取响应体（与 announce 同语义）。
  /// 不可达/超时/自端返回 null。
  Future<LsDiscoveredDevice?> _probe(
    String ip,
    int port,
    String selfFp,
    String declaredFp,
  ) async {
    final self = selfInfo?.call();
    if (self == null) return null;
    HttpClient? client;
    try {
      client = HttpClient(context: SecurityContext())
        ..connectionTimeout = const Duration(milliseconds: 500)
        ..badCertificateCallback = (cert, host, port) => true;
      final req = await client
          .postUrl(Uri.parse(
              'https://$ip:$port/api/localsend/v2/register'))
          .timeout(const Duration(milliseconds: 700));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(self.toJson()));
      final res = await req.close().timeout(const Duration(milliseconds: 700));
      final body = await utf8.decoder.bind(res).join();
      final json = jsonDecode(body);
      if (json is! Map<String, dynamic>) return null;
      final fp = '${json['fingerprint'] ?? ''}'.trim().toLowerCase();
      if (fp.isEmpty || fp == selfFp || (declaredFp.isNotEmpty && fp == declaredFp)) {
        return null;
      }
      final alias = '${json['alias'] ?? ''}'.trim();
      debugPrint('[LsDiscovery] 子网扫描发现: ${alias.isEmpty ? '未知设备' : alias}($ip:$port) fp=$fp');
      return LsDiscoveredDevice(
        fingerprint: fp,
        alias: alias.isEmpty ? '未知设备' : alias,
        ip: ip,
        port: port,
        version: '${json['version'] ?? ''}',
        deviceModel: json['deviceModel'] as String?,
        deviceType: json['deviceType'] as String?,
        download: json['download'] == true,
        lastSeen: DateTime.now(),
      );
    } catch (_) {
      return null;
    } finally {
      try {
        client?.close(force: true);
      } catch (_) {}
    }
  }

  void _announceAt(Duration delay) {
    Future.delayed(delay, () {
      if (_running) _announce();
    });
  }

  void _announce() {
    final socket = _sendSocket ?? _socket;
    final self = selfInfo?.call();
    if (socket == null || self == null) return;
    final bytes = utf8.encode(jsonEncode(lsBuildAnnounce(self)));
    final group = InternetAddress(kLsMulticastAddr);
    final targets = <InternetAddress>[
      group,
      InternetAddress('255.255.255.255'),
      ...extraBroadcastTargets,
    ];
    for (final t in targets) {
      try {
        socket.send(bytes, t, kLsDefaultPort);
      } catch (e) {
        debugPrint('[LsDiscovery] announce 发送失败 -> ${t.address}: $e');
      }
    }
    // 向已知对端补发单播 announce（对端发现 socket 源端口即接收端口）。
    // iOS 收不到组播/受限广播，靠这条通路维持双向在线刷新。
    for (final entry in _knownPeers.entries) {
      try {
        socket.send(bytes, InternetAddress(entry.key), entry.value);
      } catch (_) {}
    }
    debugPrint(
        '[LsDiscovery] announce 周期: 广播目标 ${targets.length} 个, '
        '单播保活 ${_knownPeers.length} 个 '
        '(${_knownPeers.entries.map((e) => '${e.key}:${e.value}').join(', ')})');
  }

  void _handleDatagram(Datagram dg) {
    if (dg.data.length > maxDatagramBytes) return;
    try {
      final decoded = jsonDecode(utf8.decode(dg.data));
      if (decoded is! Map<String, dynamic>) return;
      final device = lsParseAnnounce(decoded, dg.address.address);
      if (device == null) return;
      // 组播回环：忽略本端
      final selfFp = TlsIdentityService.instance.fingerprint.toLowerCase();
      final declaredFp = selfInfo?.call().fingerprint.toLowerCase() ?? '';
      final isSelf = device.fingerprint == selfFp ||
          (declaredFp.isNotEmpty && device.fingerprint == declaredFp);
      debugPrint(
          '[LsDiscovery] 收到 announce: ${device.alias}(${device.ip}:${dg.port}) '
          'fp=${device.fingerprint.length > 8 ? device.fingerprint.substring(0, 8) : device.fingerprint}'
          '${isSelf ? ' [自端回环，忽略]' : ''}');
      if (isSelf) return;
      // 记录对端发现 socket 接收端口，供周期单播 announce 保活。
      // 数据报源端口在 [53317, 53327) 内视为对端监听端口（旧版单 socket
      // 发收同端口）；新版发送走临时端口，源端口不在范围内则取默认端口
      // （对端监听 socket 优先绑定 53317，仅被占用时下移）
      final srcPort = dg.port;
      _knownPeers[device.ip] =
          (srcPort >= kLsDefaultPort && srcPort < kLsDefaultPort + 10)
              ? srcPort
              : kLsDefaultPort;
      _events.add(device);
      // 新指纹：后台 register（对端由此得知本端，官方 probe 语义）。
      // 按 TTL 周期重发：对端可能后启动/重启（如 iOS 错过首次 register
      // 就收不到反向发现），轻量 POST，20s 一次可接受
      if (_registerAttempted.containsKey(device.fingerprint)) {
        final last = _registerAttempted[device.fingerprint]!;
        if (DateTime.now().difference(last) >= registerRetryInterval) {
          _registerAttempted[device.fingerprint] = DateTime.now();
          unawaited(_registerTo(device));
        }
      } else {
        _registerAttempted[device.fingerprint] = DateTime.now();
        debugPrint(
            '[LsDiscovery] 发现新设备 ${device.alias}(${device.ip}:${device.port}) fp=${device.fingerprint}');
        unawaited(_registerTo(device));
      }
    } catch (_) {
      // 非组播载荷（本端 8888 广播不会到这里：端口不同），忽略
    }
  }

  /// POST /api/localsend/v2/register：尽力而为，失败仅记日志。
  /// TLS badCertificateCallback 按announce 指纹钉扎（TOFU）。
  Future<void> _registerTo(LsDiscoveredDevice device) async {
    final self = selfInfo?.call();
    if (self == null) return;
    HttpClient? client;
    try {
      // 空上下文（不带本端证书）：dart:io 服务端会强校验客户端证书链，
      // 携带自签证书会让对端握手直接断开；对端证书走指纹钉扎回调判定
      client = HttpClient(context: SecurityContext())
        ..connectionTimeout = const Duration(seconds: 5)
        ..badCertificateCallback = (cert, host, port) =>
            TlsIdentityService.fingerprintOfCert(cert) == device.fingerprint;
      final req = await client.postUrl(Uri.parse(
        'https://${_hostFor(device.ip)}:${device.port}/api/localsend/v2/register',
      ));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(self.toJson()));
      final res = await req.close();
      await res.drain<void>();
      debugPrint(
          '[LsDiscovery] register ${device.alias}(${device.ip}) -> ${res.statusCode}');
    } catch (e) {
      debugPrint('[LsDiscovery] register 失败 ${device.ip}（忽略）: $e');
    } finally {
      try {
        client?.close(force: true);
      } catch (_) {}
    }
  }

  /// register 反向发现：对端发现本端后 POST /register 登记自身，
  /// 服务端回调转发到这里。据此把对端加入设备流（iOS 收不到组播/广播
  /// announce 时的唯一发现通路），并按默认发现端口记录对端用于单播保活
  /// （后续收到对端数据报时源端口会自动纠正）。
  void noteRegisterPeer(LsDeviceDto peer, String ip) {
    if (ip.isEmpty || peer.fingerprint.trim().isEmpty) return;
    final selfFp = TlsIdentityService.instance.fingerprint.toLowerCase();
    final declaredFp = selfInfo?.call().fingerprint.toLowerCase() ?? '';
    final fp = peer.fingerprint.trim().toLowerCase();
    if (fp == selfFp || (declaredFp.isNotEmpty && fp == declaredFp)) {
      debugPrint('[LsDiscovery] register 自端回环忽略: $ip');
      return;
    }
    _knownPeers.putIfAbsent(ip, () => kLsDefaultPort);
    _events.add(LsDiscoveredDevice(
      fingerprint: fp,
      alias: peer.alias.trim().isEmpty ? '未知设备' : peer.alias,
      ip: ip,
      port: peer.port,
      version: peer.version,
      deviceModel: peer.deviceModel,
      deviceType: peer.deviceType,
      download: peer.download,
      lastSeen: DateTime.now(),
    ));
    debugPrint('[LsDiscovery] register 反向发现 $ip:${peer.port} fp=$fp');
  }

  void stop() {
    _running = false;
    _announceTimer?.cancel();
    _announceTimer = null;
    _scanTimer?.cancel();
    _scanTimer = null;
    _scanningIfaces.clear();
    try {
      _socket?.close();
    } catch (_) {}
    _socket = null;
    try {
      _sendSocket?.close();
    } catch (_) {}
    _sendSocket = null;
    _registerAttempted.clear();
    _knownPeers.clear();
    if (Platform.isAndroid) {
      unawaited(() async {
        try {
          await _multicastChannel.invokeMethod<void>('release');
        } catch (_) {}
      }());
    }
    debugPrint('[LsDiscovery] v2 组播发现已停止');
  }
}

/// IPv6 地址作为 URL host 需方括号；v4 原样。
String _hostFor(String ip) => ip.contains(':') ? '[$ip]' : ip;
