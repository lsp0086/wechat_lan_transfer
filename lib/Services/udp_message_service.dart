import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// UDP 消息通道服务
/// 在已有的 UDP 8888 端口上扩展消息传输能力
/// 文字消息、文件传输通知均通过此通道

enum UdpCmd {
  textMessage,    // 文字消息
  fileNotify,     // 文件传输通知（发送方通知接收方准备接收）
  fileAccept,     // 文件接收确认（接收方回复发送方已准备好）
  fileReject,     // 文件传输拒绝（接收方拒绝接收）
}

/// 设备在线状态
enum DeviceOnlineStatus {
  online,    // 在线
  offline,   // 离线
  unknown,   // 未知（刚启动尚未收到心跳）
}

/// 设备在线状态变更回调
typedef DeviceStatusCallback = void Function(String deviceId, DeviceOnlineStatus status);

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
  static const int msgPort = 8888; // 与设备发现共用端口
  static const Duration heartbeatTimeout = Duration(seconds: 10); // 10秒无心跳视为离线

  RawDatagramSocket? _socket;
  bool _isRunning = false;
  String _localIP = '';

  final StreamController<ReceivedMessage> _messageController =
      StreamController<ReceivedMessage>.broadcast();

  // 心跳超时检测
  final Map<String, DateTime> _lastHeartbeat = {};
  Timer? _heartbeatCheckTimer;
  DeviceStatusCallback? _onDeviceStatusChanged;

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

  /// 初始化：绑定到已有端口，或绑定新端口
  Future<bool> init(String localIP) async {
    _localIP = localIP;
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        msgPort,
        reuseAddress: true,
      );
      _isRunning = true;

      _socket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          Datagram? dg = _socket?.receive();
          if (dg != null) {
            _handleDatagram(dg);
          }
        }
      });

      debugPrint('[UdpMsgService] 消息通道已启动，绑定端口 $msgPort');
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
    _isRunning = true;
    _startHeartbeatCheck();
    debugPrint('[UdpMsgService] 已附加到外部 UDP Socket, localIP=$localIP');
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

  /// 处理接收到的数据报
  void _handleDatagram(Datagram dg) {
    try {
      final rawData = utf8.decode(dg.data);
      final decoded = jsonDecode(rawData);
      if (decoded is! Map<String, dynamic>) return;

      final cmdStr = decoded['cmd'] as String?;
      if (cmdStr == null) return;

      // 只处理消息类命令，忽略设备发现命令
      UdpCmd? cmd;
      switch (cmdStr) {
        case 'text_msg':
          cmd = UdpCmd.textMessage;
          break;
        case 'file_notify':
          cmd = UdpCmd.fileNotify;
          break;
        case 'file_accept':
          cmd = UdpCmd.fileAccept;
          break;
        case 'file_reject':
          cmd = UdpCmd.fileReject;
          break;
        default:
          return; // 不是消息命令，忽略（可能是设备发现包）
      }

      final msg = ReceivedMessage(
        senderIp: dg.address.address,
        cmd: cmd,
        payload: Map<String, dynamic>.from(decoded),
      );

      _messageController.add(msg);
      debugPrint('[UdpMsgService] 收到消息: cmd=$cmdStr from=${dg.address.address}');
    } catch (e) {
      // 解析失败，可能是设备发现包或其他格式，忽略
    }
  }

  /// 处理原始数据（供外部 Socket 回调使用，与 chat_list 共享时）
  void handleRawData(String rawData, String senderIP) {
    try {
      final decoded = jsonDecode(rawData);
      if (decoded is! Map<String, dynamic>) return;

      final cmdStr = decoded['cmd'] as String?;
      if (cmdStr == null) return;

      UdpCmd? cmd;
      switch (cmdStr) {
        case 'text_msg':
          cmd = UdpCmd.textMessage;
          break;
        case 'file_notify':
          cmd = UdpCmd.fileNotify;
          break;
        case 'file_accept':
          cmd = UdpCmd.fileAccept;
          break;
        case 'file_reject':
          cmd = UdpCmd.fileReject;
          break;
        default:
          return; // 设备发现包
      }

      final msg = ReceivedMessage(
        senderIp: senderIP,
        cmd: cmd,
        payload: Map<String, dynamic>.from(decoded),
      );

      _messageController.add(msg);
      debugPrint('[UdpMsgService] 收到消息: cmd=$cmdStr from=$senderIP');
    } catch (_) {}
  }

  /// 发送文字消息
  Future<bool> sendTextMessage({
    required String targetIp,
    required String content,
    required String senderName,
  }) async {
    return _send(targetIp, {
      'cmd': 'text_msg',
      'content': content,
      'senderName': senderName,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  /// 发送文件传输通知（告知对方即将发送文件）
  Future<bool> sendFileNotify({
    required String targetIp,
    required String fileName,
    required int fileSize,
    required String senderName,
  }) async {
    return _send(targetIp, {
      'cmd': 'file_notify',
      'fileName': fileName,
      'fileSize': fileSize,
      'senderName': senderName,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  /// 发送文件接收确认（告知发送方已准备好接收）
  Future<bool> sendFileAccept({
    required String targetIp,
    required String originalFileName,
  }) async {
    return _send(targetIp, {
      'cmd': 'file_accept',
      'fileName': originalFileName,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  /// 发送文件传输拒绝（告知发送方拒绝接收）
  Future<bool> sendFileReject({
    required String targetIp,
    required String originalFileName,
  }) async {
    return _send(targetIp, {
      'cmd': 'file_reject',
      'fileName': originalFileName,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  /// 底层发送
  Future<bool> _send(String targetIp, Map<String, dynamic> data) async {
    if (_socket == null || !_isRunning) {
      debugPrint('[UdpMsgService] Socket 未就绪，无法发送 (socket=${_socket != null}, running=$_isRunning)');
      return false;
    }

    try {
      final jsonStr = jsonEncode(data);
      final bytes = utf8.encode(jsonStr);
      _socket!.send(bytes, InternetAddress(targetIp), msgPort);
      debugPrint('[UdpMsgService] 已发送 ${data['cmd']} -> $targetIp:$msgPort (${bytes.length} bytes)');
      return true;
    } catch (e) {
      debugPrint('[UdpMsgService] 发送失败: $e');
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
