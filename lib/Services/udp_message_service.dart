import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:wechat_lan_transfer/Services/protocol_codec.dart';
import 'package:wechat_lan_transfer/Services/tls_identity_service.dart';

/// UDP 消息通道服务
/// 默认端口 8888（P1-1 可配置 + 占用探测回退），文字/文件握手均走此通道

enum UdpCmd {
  textMessage, // 文字消息
  fileMeta, // v2 fileMeta side-channel（气泡显示用元数据，传输走 v2 HTTPS）
  msgAck, // 消息确认（接收方确认收到某条消息）
  ping, // 在线探测请求
  pong, // 在线探测响应
  blockSync, // 拉黑状态同步（主动推送，不等心跳）
}

/// 设备在线状态
enum DeviceOnlineStatus {
  online, // 在线
  offline, // 离线
  unknown, // 未知（刚启动尚未收到心跳）
}

/// 设备在线状态变更回调
typedef DeviceStatusCallback =
    void Function(String deviceId, DeviceOnlineStatus status);

/// 收到的消息封装
class ReceivedMessage {
  final String senderIp;
  final UdpCmd cmd;
  final Map<String, dynamic> payload;

  ReceivedMessage({
    required this.senderIp,
    required this.cmd,
    required this.payload,
  });
}

class UdpMessageService {
  static const int defaultMsgPort = 8888; // 与设备发现共用端口（P1-1 可配置）
  static const Duration heartbeatTimeout = Duration(seconds: 10); // 10秒无心跳视为离线

  RawDatagramSocket? _socket;
  bool _isRunning = false;
  String _localIP = '';

  /// P1-1：本端实际绑定的 UDP 端口（探测回退后可能不是默认 8888）
  int _boundPort = defaultMsgPort;

  /// P1-1：对端 UDP 端口（按 IP 索引；旧端缺省 defaultMsgPort）
  final Map<String, int> _peerUdpPortByIp = {};

  int get boundPort => _boundPort;

  /// 兼容旧调用：本端实际端口
  int get msgPort => _boundPort;

  final StreamController<ReceivedMessage> _messageController =
      StreamController<ReceivedMessage>.broadcast();

  // 心跳超时检测
  final Map<String, DateTime> _lastHeartbeat = {};
  Timer? _heartbeatCheckTimer;
  DeviceStatusCallback? _onDeviceStatusChanged;

  // Ping/Pong 实时探测
  final Map<String, Completer<bool>> _pingCompleters = {};
  int _pingIdCounter = 0;

  /// v2 fileMeta side-channel 接收缓存（fileName+size -> FileMeta）。
  final FileMetaCache fileMetaCache = FileMetaCache();

  /// P0-S1：nonce 去重（nonce -> 过期毫秒时间戳，TTL=时间窗），防重放。
  final Map<String, int> _seenNonces = {};

  /// P0-S1/P1-T8：per-IP 简易限流（每 IP 每秒最多 30 包，超限丢弃）。
  static const int maxPacketsPerSecondPerIp = 30;

  /// E5：UDP 包长度上限与 ProtocolCodec 统一（60KB），超限丢弃。
  static const int maxUdpBytes = ProtocolCodec.maxUdpPacketBytes;

  /// P0-S1：nonce 去重窗口（秒）+ 最大保留数。
  static const int nonceWindowSec = 30;
  static const int maxNonces = 1000;
  final Map<String, List<int>> _ipPacketTimesMs = {};

  /// P0-S1：per-IP 限流。每 IP 每秒最多 30 包。
  bool _allowPacket(String ip) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final times = _ipPacketTimesMs.putIfAbsent(ip, () => <int>[]);
    times.removeWhere((t) => now - t > 1000);
    if (times.length >= maxPacketsPerSecondPerIp) return false;
    times.add(now);
    return true;
  }

  /// P0-S1：nonce 去重。已见过返回 false（重放），否则记录并返回 true。
  bool _noteNonce(String nonce) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final expired = <String>[];
    _seenNonces.forEach((k, exp) {
      if (now > exp) expired.add(k);
    });
    for (final k in expired) {
      _seenNonces.remove(k);
    }
    if (_seenNonces.containsKey(nonce)) return false;
    // 保留最近 1000 个：超限时删最早插入的
    if (_seenNonces.length >= maxNonces) {
      _seenNonces.remove(_seenNonces.keys.first);
    }
    _seenNonces[nonce] = now + nonceWindowSec * 1000;
    return true;
  }

  /// P0-S1/S6：版本/时间窗/nonce/设备绑定/HMAC 校验。
  /// S1：若同时带 tlsFp+hmac 则验签，不一致丢弃（防损坏/随手伪造；
  /// 指纹明文可嗅探，强鉴别靠 TLS 钉扎+PIN，此处仅做完整性绑定）。
  /// S6：legacyGraceUntil 之后缺 ts/nonce 直接丢弃，不再兼容放行。
  bool _validateAuthFields(Map<String, dynamic> p) {
    // 版本：未知版本拒绝
    if (p.containsKey('v')) {
      final v = p['v'];
      int? vv;
      if (v is int) {
        vv = v;
      } else {
        vv = int.tryParse('$v');
      }
      if (vv != null && vv != ProtocolCodec.protocolVersion) {
        debugPrint('[UdpMsgService] 拒绝未知协议版本 v=$v');
        return false;
      }
    }
    // 时间戳：优先新 `ts`，兼容旧 `timestamp`
    // S6：宽限期后缺字段直接丢弃
    final strictLegacy =
        DateTime.now().toUtc().isAfter(ProtocolCodec.legacyGraceUntil);
    final hasTs = p.containsKey('ts');
    final hasTimestamp =
        p.containsKey('timestamp') && '${p['timestamp']}'.isNotEmpty;
    if (hasTs) {
      if (!ProtocolCodec.isTimestampFresh(p['ts'])) {
        debugPrint('[UdpMsgService] 丢弃过期包 ts=${p['ts']}');
        return false;
      }
    } else if (hasTimestamp) {
      if (!ProtocolCodec.isFreshTimestamp('${p['timestamp']}')) {
        debugPrint('[UdpMsgService] 丢弃过期包 timestamp=${p['timestamp']}');
        return false;
      }
    } else if (strictLegacy) {
      debugPrint('[UdpMsgService] S6 宽限过期，缺时间戳直接丢弃 cmd=${p['cmd']}');
      return false;
    } else {
      debugPrint('[UdpMsgService] 兼容旧端：缺时间戳字段，放行 cmd=${p['cmd']}');
    }
    // nonce 去重（缺字段时兼容放行，宽限过期后丢弃）
    final nonce = p['nonce'];
    if (nonce is String && nonce.isNotEmpty) {
      if (!_noteNonce(nonce)) {
        debugPrint('[UdpMsgService] 丢弃重放包 nonce=$nonce');
        return false;
      }
    } else if (strictLegacy) {
      debugPrint('[UdpMsgService] S6 宽限过期，缺 nonce 直接丢弃 cmd=${p['cmd']}');
      return false;
    } else {
      debugPrint('[UdpMsgService] 兼容旧端：缺 nonce 字段，放行 cmd=${p['cmd']}');
    }
    // 设备绑定：同时含 deviceId 与 tlsFp 但不一致则丢弃
    final d = p['deviceId'];
    final f = p['tlsFp'];
    final hasD = d is String && d.isNotEmpty;
    final hasF = f is String && f.isNotEmpty;
    if (hasD && hasF && d != f) {
      debugPrint('[UdpMsgService] 丢弃设备绑定不一致包 deviceId=$d tlsFp=$f');
      return false;
    }
    // S1：HMAC 验签（key=声明的 tlsFp，绑定载荷防篡改；防伪造靠 TLS+PIN）。
    // 有 hmac 必验；缺 hmac 宽限期内放行+日志，宽限过期后丢弃。
    final h = p['hmac'];
    final hasH = h is String && h.isNotEmpty;
    if (hasH) {
      if (!hasF) {
        debugPrint('[UdpMsgService] 丢弃无指纹却带 hmac 的包');
        return false;
      }
      if (!ProtocolCodec.verifyHmac(p, f)) {
        debugPrint('[UdpMsgService] 丢弃 HMAC 校验失败包 cmd=${p['cmd']}');
        return false;
      }
    } else if (strictLegacy) {
      debugPrint('[UdpMsgService] S6 宽限过期，缺 hmac 直接丢弃 cmd=${p['cmd']}');
      return false;
    } else {
      debugPrint('[UdpMsgService] 兼容旧端：缺 hmac 字段，放行 cmd=${p['cmd']}');
    }
    return true;
  }

  /// 实时探测目标设备是否在线（发送 ping 并等待 pong 响应）
  /// [timeout] 默认 2 秒，LAN 环境足够
  Future<bool> pingDevice(
    String deviceId, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final pingId =
        'ping_${++_pingIdCounter}_${DateTime.now().millisecondsSinceEpoch}';
    final completer = Completer<bool>();
    _pingCompleters[pingId] = completer;

    // 发送 ping
    final sent = await _send(deviceId, {'cmd': 'ping', 'pingId': pingId});

    if (!sent) {
      _pingCompleters.remove(pingId);
      return false;
    }

    try {
      return await completer.future.timeout(
        timeout,
        onTimeout: () {
          _pingCompleters.remove(pingId);
          return false;
        },
      );
    } catch (_) {
      _pingCompleters.remove(pingId);
      return false;
    }
  }

  /// 收到 ping 请求，自动回复 pong
  void _handlePing(String senderIp, String pingId) {
    _send(senderIp, {'cmd': 'pong', 'pingId': pingId});
  }

  /// 收到 pong 响应，完成对应的 Completer
  void _handlePong(String pingId) {
    final completer = _pingCompleters.remove(pingId);
    completer?.complete(true);
  }

  Stream<ReceivedMessage> get messageStream => _messageController.stream;
  String get localIP => _localIP;
  bool get isRunning => _isRunning;

  /// 注册设备状态变更回调
  void setDeviceStatusCallback(DeviceStatusCallback? callback) {
    _onDeviceStatusChanged = callback;
  }

  /// 记录收到某设备的心跳
  void recordHeartbeat(String deviceId) {
    _lastHeartbeat[deviceId] = DateTime.now();
  }

  /// 获取设备是否在线
  bool isDeviceOnline(String deviceId) {
    final lastBeat = _lastHeartbeat[deviceId];
    if (lastBeat == null) return false;
    return DateTime.now().difference(lastBeat) < heartbeatTimeout;
  }

  /// P1-3：距上次心跳的时长；从未收到则返回 null
  Duration? heartbeatAge(String deviceId) {
    final lastBeat = _lastHeartbeat[deviceId];
    if (lastBeat == null) return null;
    return DateTime.now().difference(lastBeat);
  }

  /// 初始化：绑定到已有端口，或绑定新端口
  Future<bool> init(String localIP, {int port = defaultMsgPort}) async {
    _localIP = localIP;
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        reuseAddress: true,
      );
      _boundPort = _socket!.port;
      _isRunning = true;

      _socket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          Datagram? dg = _socket?.receive();
          if (dg != null) {
            _handleDatagram(dg);
          }
        }
      });

      debugPrint('[UdpMsgService] 消息通道已启动，绑定端口 $_boundPort');
      return true;
    } catch (e) {
      // 端口可能已被 chat_list 的 UDP Socket 占用
      // 尝试复用已有 Socket
      debugPrint('[UdpMsgService] 绑定端口失败（可能已被占用）: $e');
      return false;
    }
  }

  /// 使用外部已有的 RawDatagramSocket（与 chat_list 共享）
  void attachToExisting(RawDatagramSocket socket, String localIP) {
    _socket = socket;
    _localIP = localIP;
    _boundPort = socket.port;
    _isRunning = true;
    _startHeartbeatCheck();
    debugPrint(
      '[UdpMsgService] 已附加到外部 UDP Socket, localIP=$localIP port=$_boundPort',
    );
  }

  /// P1-1：记录对端实际 UDP 端口（来自发现广播/数据报源端口）
  void rememberPeerUdpPort(String ip, int port) {
    if (ip.isEmpty || ip == '0.0.0.0') return;
    if (port <= 0 || port > 65535) return;
    _peerUdpPortByIp[ip] = port;
  }

  int _portFor(String targetIp) => _peerUdpPortByIp[targetIp] ?? defaultMsgPort;

  /// P1-N6：端口回退发送。先试记住端口（`_send`），失败则轮询
  /// defaultMsgPort 与 ±10 端口（加 `extraPorts`），逐个直发。
  Future<bool> sendWithPortFallback(
    String targetIp,
    Map<String, dynamic> data, {
    List<int> extraPorts = const [],
  }) async {
    if (await _send(targetIp, data)) return true;
    if (_socket == null || !_isRunning) return false;
    final tried = <int>{_portFor(targetIp)};
    final candidates = <int>[defaultMsgPort];
    for (int d = 1; d <= 10; d++) {
      candidates.add(defaultMsgPort + d);
      candidates.add(defaultMsgPort - d);
    }
    candidates.addAll(extraPorts);
    for (final port in candidates) {
      if (port < 1 || port > 65535 || !tried.add(port)) continue;
      try {
        final jsonStr = jsonEncode(data);
        final bytes = utf8.encode(jsonStr);
        _socket!.send(bytes, InternetAddress(targetIp), port);
        debugPrint('[UdpMsgService] P1-N6 端口回退发送成功 -> $targetIp:$port');
        rememberPeerUdpPort(targetIp, port);
        return true;
      } catch (e) {
        debugPrint('[UdpMsgService] P1-N6 回退端口 $port 发送失败: $e');
      }
    }
    debugPrint('[UdpMsgService] P1-N6 所有回退端口均失败 target=$targetIp，请检查对端 UDP 端口');
    return false;
  }

  /// 启动心跳超时检测定时器
  void _startHeartbeatCheck() {
    _heartbeatCheckTimer?.cancel();
    _heartbeatCheckTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      final now = DateTime.now();
      final List<String> offlineDevices = [];
      _lastHeartbeat.forEach((deviceId, lastBeat) {
        if (now.difference(lastBeat) >= heartbeatTimeout) {
          offlineDevices.add(deviceId);
        }
      });
      for (final deviceId in offlineDevices) {
        _lastHeartbeat.remove(deviceId);
        debugPrint('[UdpMsgService] 设备 $deviceId 心跳超时，标记为离线');
        _onDeviceStatusChanged?.call(deviceId, DeviceOnlineStatus.offline);
      }
    });
  }

  /// 解析命令字符串为 UdpCmd 枚举
  UdpCmd? _parseCmd(String cmdStr) {
    switch (cmdStr) {
      case 'text_msg':
        return UdpCmd.textMessage;
      case 'file_meta':
        return UdpCmd.fileMeta;
      case 'msg_ack':
        return UdpCmd.msgAck;
      case 'ping':
        return UdpCmd.ping;
      case 'pong':
        return UdpCmd.pong;
      case 'block_sync':
        return UdpCmd.blockSync;
      default:
        return null; // 设备发现包等非消息命令
    }
  }

  /// 解析真实发送方 IP：UDP 包头 IP 为空或 0.0.0.0 时，用 payload.senderIp 兜底
  String _resolveSenderIp(String rawUdpIp, Map<String, dynamic> payload) {
    if (rawUdpIp.isNotEmpty && rawUdpIp != '0.0.0.0') {
      return rawUdpIp;
    }
    final payloadIp = payload['senderIp'] as String?;
    if (payloadIp != null && payloadIp.isNotEmpty && payloadIp != '0.0.0.0') {
      debugPrint(
        '[UdpMsgService] ⚠️ UDP 包头 IP 为 "$rawUdpIp"，回退到 payload.senderIp="$payloadIp"',
      );
      return payloadIp;
    }
    // 都无效时返回原始值，避免空串导致后续逻辑崩坏
    return rawUdpIp.isNotEmpty ? rawUdpIp : 'unknown';
  }

  /// 处理接收到的数据报
  void _handleDatagram(Datagram dg) {
    // P0-S1/P1-T8：单包上限校验，超限直接丢弃不做 jsonDecode
    if (dg.data.length > ProtocolCodec.maxUdpPacketBytes) {
      debugPrint(
        '[UdpMsgService] 丢弃超大 UDP 包: ${dg.data.length}B from=${dg.address.address}',
      );
      return;
    }
    final senderIpForLimit = dg.address.address;
    if (!_allowPacket(senderIpForLimit)) {
      debugPrint('[UdpMsgService] per-IP 限流丢弃: $senderIpForLimit');
      return;
    }
    try {
      final rawData = utf8.decode(dg.data);
      final decoded = jsonDecode(rawData);
      if (decoded is! Map<String, dynamic>) return;

      // P0-S1：版本/时间窗/nonce 校验（ping/pong 同样校验）
      if (!_validateAuthFields(decoded)) return;

      final cmdStr = decoded['cmd'] as String?;
      if (cmdStr == null) return;

      // ping/pong 直接处理，不进入消息流
      if (cmdStr == 'ping') {
        final realIp = _resolveSenderIp(dg.address.address, decoded);
        _handlePing(realIp, decoded['pingId'] as String? ?? '');
        return;
      }
      if (cmdStr == 'pong') {
        _handlePong(decoded['pingId'] as String? ?? '');
        return;
      }
      // v2 fileMeta side-channel：内部入缓存，不进入消息流
      if (cmdStr == 'file_meta') {
        _handleFileMeta(decoded);
        return;
      }

      final cmd = _parseCmd(cmdStr);
      if (cmd == null) return; // 非消息命令，忽略

      final senderIp = _resolveSenderIp(dg.address.address, decoded);

      final msg = ReceivedMessage(
        senderIp: senderIp,
        cmd: cmd,
        payload: Map<String, dynamic>.from(decoded),
      );

      _messageController.add(msg);
      debugPrint(
        '[UdpMsgService] 收到消息: cmd=$cmdStr from=$senderIp (raw=${dg.address.address})',
      );
    } catch (e) {
      // 解析失败，可能是设备发现包或其他格式，忽略
    }
  }

  /// 处理原始数据（供外部 Socket 回调使用，与 chat_list 共享时）
  void handleRawData(String rawData, String senderIP) {
    // P0-S1：包长度上限 64KB，超限丢弃
    if (utf8.encode(rawData).length > maxUdpBytes) {
      debugPrint('[UdpMsgService] 丢弃超大 UDP 包(64KB+): from=$senderIP');
      return;
    }
    if (!_allowPacket(senderIP)) {
      debugPrint('[UdpMsgService] per-IP 限流丢弃: $senderIP');
      return;
    }
    try {
      final decoded = jsonDecode(rawData);
      if (decoded is! Map<String, dynamic>) return;

      // P0-S1：版本/时间窗/nonce/设备绑定校验
      if (!_validateAuthFields(decoded)) return;

      final cmdStr = decoded['cmd'] as String?;
      if (cmdStr == null) return;

      // ping/pong 直接处理，不进入消息流
      if (cmdStr == 'ping') {
        final realIp = _resolveSenderIp(senderIP, decoded);
        _handlePing(realIp, decoded['pingId'] as String? ?? '');
        return;
      }
      if (cmdStr == 'pong') {
        _handlePong(decoded['pingId'] as String? ?? '');
        return;
      }
      // v2 fileMeta side-channel：内部入缓存，不进入消息流
      if (cmdStr == 'file_meta') {
        _handleFileMeta(decoded);
        return;
      }

      final cmd = _parseCmd(cmdStr);
      if (cmd == null) return; // 设备发现包

      final realIp = _resolveSenderIp(senderIP, decoded);

      final msg = ReceivedMessage(
        senderIp: realIp,
        cmd: cmd,
        payload: Map<String, dynamic>.from(decoded),
      );

      _messageController.add(msg);
      debugPrint(
        '[UdpMsgService] 收到消息: cmd=$cmdStr from=$realIp (raw=$senderIP)',
      );
    } catch (_) {}
  }

  /// 发送文字消息（含消息ID，用于ACK确认）
  /// S5：[peerFingerprint] 非空时对 content 加密为 cipher 字段（旧端忽略 cipher 仍读 content）。
  /// 加密成功后 content 置为占位文，真正的明文只在两端本地可读。
  Future<bool> sendTextMessage({
    required String targetIp,
    required String content,
    required String senderName,
    String? msgId,
    String? peerFingerprint,
  }) async {
    // S5：加密文字通道——双方指纹派生共享密钥（key 与顺序无关），加密后 content 不发明文。
    String? cipher;
    String shown = content;
    final localFp = TlsIdentityService.instance.fingerprint;
    final peerFp = (peerFingerprint ?? '').trim();
    if (localFp.isNotEmpty && peerFp.isNotEmpty) {
      final shared = ProtocolCodec.deriveTextSharedKey(localFp, peerFp);
      if (shared.isNotEmpty) {
        final enc = ProtocolCodec.encryptText(content, shared);
        if (enc.isNotEmpty) {
          cipher = enc;
          // 兜底：若通道被旧端（不支持 cipher）收走，content 只放占位提示。
          shown = '[已加密消息，请升级到此版本查看]';
        }
      }
    }
    return _send(targetIp, {
      'cmd': 'text_msg',
      'content': shown,
      if (cipher != null && cipher.isNotEmpty) 'cipher': cipher,
      'senderName': senderName,
      'timestamp': DateTime.now().toIso8601String(),
      'msgId': msgId ?? DateTime.now().millisecondsSinceEpoch.toString(),
    });
  }

  /// S5：解密接收到的 cipher 字段；失败返回 null（调用方按无法解密处理）。
  static String? decryptIncomingText(Map<String, dynamic> payload) {
    final cipher = payload['cipher'];
    if (cipher is! String || cipher.isEmpty) return null;
    final peerFp = (payload['deviceId'] as String?) ?? payload['tlsFp'] as String?;
    final localFp = TlsIdentityService.instance.fingerprint;
    if (peerFp == null || peerFp.isEmpty || localFp.isEmpty) return null;
    final shared = ProtocolCodec.deriveTextSharedKey(localFp, peerFp);
    if (shared.isEmpty) return null;
    return ProtocolCodec.decryptText(cipher, shared);
  }

  /// v2 fileMeta side-channel：发送气泡显示用元数据（语音波形/文件夹标记等）。
  /// 官方 LocalSend 的文件元数据在 prepare-upload 请求体里，但 UI 需在
  /// 弹窗/落盘前知道类型，故经 UDP 提前发（连发 2 次抗丢包）。
  /// 接收端按 fileName+size 入缓存，v2 会话到达时取回（见 FileMetaCache）。
  Future<bool> sendFileMeta({
    required String targetIp,
    required String fileName,
    required int fileSize,
    bool isFolder = false,
    bool isVoice = false,
    int? durationMs,
    String? waveformData,
  }) async {
    final data = <String, dynamic>{
      'cmd': 'file_meta',
      'fileName': fileName,
      'fileSize': fileSize,
      'isFolder': isFolder,
      'isVoice': isVoice,
      if (durationMs != null && durationMs > 0) 'durationMs': durationMs,
      if (waveformData?.isNotEmpty == true) 'waveformData': waveformData,
      'timestamp': DateTime.now().toIso8601String(),
    };
    // 丢包兜底：连发两次
    final first = await _send(targetIp, data);
    final second = await _send(targetIp, data);
    return first || second;
  }

  /// 收到 file_meta：入缓存（fileName+size 键），供 v2 会话到达时取回。
  void _handleFileMeta(Map<String, dynamic> p) {
    final fileName = p['fileName'];
    final fileSize = p['fileSize'];
    if (fileName is! String || fileName.isEmpty) return;
    final size = fileSize is num ? fileSize.toInt() : int.tryParse('$fileSize');
    if (size == null || size < 0) return;
    fileMetaCache.put(
      fileMetaKey(fileName, size),
      FileMeta(
        isFolder: p['isFolder'] == true,
        isVoice: p['isVoice'] == true,
        durationMs: p['durationMs'] is num ? (p['durationMs'] as num).toInt() : null,
        waveformData: p['waveformData'] is String ? p['waveformData'] as String : null,
      ),
    );
  }

  /// 发送消息确认（ACK）— 告知发送方消息已收到。
  /// [blocked] 为 true 表示接收方已拉黑发送方，消息被拒收。
  Future<bool> sendMsgAck({
    required String targetIp,
    required String msgId,
    bool blocked = false,
  }) async {
    final payload = <String, dynamic>{
      'cmd': 'msg_ack',
      'msgId': msgId,
      'timestamp': DateTime.now().toIso8601String(),
    };
    if (blocked) {
      payload['blocked'] = true;
    }
    return _send(targetIp, payload);
  }

  /// 发送拉黑状态同步（主动推送，不等心跳）。
  /// [blocked] 为 true 表示已拉黑对方，false 表示已解除拉黑。
  Future<bool> sendBlockSync({
    required String targetIp,
    required bool blocked,
  }) async {
    return _send(targetIp, {
      'cmd': 'block_sync',
      'blocked': blocked,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  /// 底层发送：自动附上发送方 IP，接收方可兜底 UDP 包头 0.0.0.0 的情况
  Future<bool> _send(String targetIp, Map<String, dynamic> data) async {
    if (_socket == null || !_isRunning) {
      debugPrint(
        '[UdpMsgService] Socket 未就绪，无法发送 (socket=${_socket != null}, running=$_isRunning)',
      );
      return false;
    }

    // 自动附加发送方 IP（协议各消息不重复携带时），解决 UDP 包头 senderIP 可能为 0.0.0.0 的问题
    if (!data.containsKey('senderIp') &&
        _localIP.isNotEmpty &&
        _localIP != '未知IP') {
      data['senderIp'] = _localIP;
      debugPrint('[UdpMsgService] 附加 senderIp=$_localIP -> cmd=${data['cmd']}');
    }

    // P0-1：统一附加本端 TLS 证书指纹，file_notify/file_accept 等握手消息
    // 自动携带，旧端收到多余字段直接忽略（天然兼容）
    final tlsFp = TlsIdentityService.instance.fingerprint;
    if (tlsFp.isNotEmpty && !data.containsKey('tlsFp')) {
      data['tlsFp'] = tlsFp;
    }

    // P0-S1：自动附加 timestamp/nonce/deviceId（如已有不覆盖，旧端兼容）
    if (!data.containsKey('timestamp') || '${data['timestamp']}'.isEmpty) {
      data['timestamp'] = DateTime.now().toIso8601String();
    }
    if (!data.containsKey('nonce') || '${data['nonce']}'.isEmpty) {
      data['nonce'] = ProtocolCodec.newNonce();
    }
    if (!data.containsKey('deviceId') || '${data['deviceId']}'.isEmpty) {
      if (tlsFp.isNotEmpty) data['deviceId'] = tlsFp;
    }

    // P0-S1：HMAC-SHA256 鉴别，key 为本端 fingerprint；为空则跳过签名
    if (tlsFp.isNotEmpty && !data.containsKey('hmac')) {
      try {
        data['hmac'] = ProtocolCodec.hmacFor(data, tlsFp);
      } catch (e) {
        debugPrint('[UdpMsgService] HMAC 计算失败，跳过签名: $e');
      }
    }

    try {
      final jsonStr = jsonEncode(data);
      final bytes = utf8.encode(jsonStr);
      final destPort = _portFor(targetIp);
      _socket!.send(bytes, InternetAddress(targetIp), destPort);
      debugPrint(
        '[UdpMsgService] 已发送 ${data['cmd']} -> $targetIp:$destPort (${bytes.length} bytes)',
      );
      return true;
    } catch (e) {
      // P1-N6：发送异常多半是目标端口不对（对端回退了端口但广播丢失），
      // 提示检查端口，可改用 sendWithPortFallback 回扫。
      debugPrint('[UdpMsgService] 发送失败（可能目标端口不对，请检查对端 UDP 端口）: $e');
      return false;
    }
  }

  void dispose() {
    _isRunning = false;
    _heartbeatCheckTimer?.cancel();
    _messageController.close();
    // 不关闭 _socket，因为可能与 chat_list 共享
  }
}

/// v2 会话气泡显示用元数据（fileMeta side-channel 载荷）。
/// 官方 LocalSend App 发来的没有 meta → 全空，按普通文件气泡处理。
class FileMeta {
  final bool isFolder;
  final bool isVoice;
  final int? durationMs;
  final String? waveformData;

  const FileMeta({
    this.isFolder = false,
    this.isVoice = false,
    this.durationMs,
    this.waveformData,
  });
}

/// fileMeta 缓存键：文件名 + 字节数（同名不同大小时不串扰）。
String fileMetaKey(String fileName, int fileSize) => '$fileName|$fileSize';

/// fileMeta LRU+TTL 缓存。v2 会话到达时按 fileName+size 取回并移除。
class FileMetaCache {
  FileMetaCache({this.maxEntries = 50, Duration? ttl})
      : ttl = ttl ?? const Duration(minutes: 5);

  final int maxEntries;
  final Duration ttl;
  final Map<String, DateTime> _at = {};
  final Map<String, FileMeta> _map = {};

  void put(String key, FileMeta meta) {
    final now = DateTime.now();
    _map[key] = meta;
    _at[key] = now;
    _evictExpired(now);
    // LRU：超限删最早写入
    while (_map.length > maxEntries) {
      String? oldest;
      DateTime? oldestAt;
      for (final e in _at.entries) {
        if (oldestAt == null || e.value.isBefore(oldestAt)) {
          oldest = e.key;
          oldestAt = e.value;
        }
      }
      if (oldest == null) break;
      _map.remove(oldest);
      _at.remove(oldest);
    }
  }

  /// 取回并移除（一次消费；重试场景发送端会重发 meta）。
  FileMeta? take(String key) {
    final at = _at[key];
    if (at == null) return null;
    if (DateTime.now().difference(at) > ttl) {
      _map.remove(key);
      _at.remove(key);
      return null;
    }
    _at.remove(key);
    return _map.remove(key);
  }

  void _evictExpired(DateTime now) {
    final expired = <String>[];
    _at.forEach((k, at) {
      if (now.difference(at) > ttl) expired.add(k);
    });
    for (final k in expired) {
      _map.remove(k);
      _at.remove(k);
    }
  }
}
