import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:collection/collection.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:desktop_drop/desktop_drop.dart';
import '../Services/udp_message_service.dart';
import '../Services/tls_identity_service.dart';
import '../Services/message_cache_service.dart';
import '../Services/toast_utils.dart';
import '../Services/app_config_store.dart';
import '../Services/auto_receive_store.dart';
import '../Model/device_info.dart';
import '../Services/lan_utils.dart';
import '../Services/lan_discovery_service.dart';
import 'chat_page.dart';
import 'pairing_dialog.dart';
import 'settings_tab.dart';
import '../Model/chat_model.dart';
import '../Transfer/ls_dto.dart';
import '../Transfer/ls_server.dart';
import '../Transfer/ls_discovery.dart';
import '../Services/free_space.dart';
import '../Services/text_retry_policy.dart';
// E1(上帝类拆分)已完成：剩余均为握手流程/心跳回调的 setState/IO/导航宿主编排，
// 判定/文案/常量/日志/变异已全部抽至 Services 纯函数（见 P1 任务清单 E1 条目）。
// 已抽出：lan_discovery_service（socket 生命周期/广播/单播/v4-v6 共用监听）、
// settings_tab（设置 Tab + 对话框群）、pairing_dialog（首次配对确认 UI）、
// paired_device_store（配对/拉黑状态）、Transfer/ls_server（v2 接收管线事件）、
// Transfer/ls_discovery（v2 组播发现）、device_name（设备名探测）、
// device_key_resolver.resolveBroadcastIdentity（广播身份）。
// DeviceInfo/ LanUtils 已抽出（见 P2-1）。
import '../Services/device_list_store.dart';
import '../Services/device_key_resolver.dart' as dkr;
import '../Services/paired_device_store.dart';
import '../Services/peer_presence.dart';
import '../Services/file_size_format.dart';
import '../Services/offline_text_queue.dart';
import '../Services/device_name.dart';
import '../Services/session_tracker.dart';
import '../Services/storage_config.dart';
import '../Services/mdns_discovery.dart';
import '../Services/time_format.dart';
import '../Services/device_sort.dart';
import '../Services/receive_dialog_texts.dart';
import '../Services/announce_payload.dart';
import '../Services/local_ip_picker.dart';
import '../Services/send_path_classify.dart';
import '../Services/share_classify.dart';
import '../Services/transfer_state_map.dart';
import '../Services/transfer_texts.dart';
import '../Services/cancel_texts.dart';
import '../Services/device_lookup.dart';
import '../Services/arrival_texts.dart';
import '../Services/device_merge.dart';
import '../Services/device_tile_meta.dart';
import '../Services/pin_texts.dart';
import '../Services/peer_identity.dart';
import '../Services/pairing_texts.dart';
import '../Services/text_inbound.dart';
import '../Services/text_edit.dart';
import '../Services/chat_list_texts.dart';
import '../Services/chat_list_logs.dart';
import '../Services/send_waiting_texts.dart';
import '../Services/message_factory.dart';
import '../Services/chat_defaults.dart';
import '../Services/transfer_limits.dart';
import '../Services/security_event.dart';
import '../Services/platform_info.dart';
import '../Services/app_clock.dart';
import '../Services/send_naming.dart';
import '../Services/bubble_meta.dart';



class ChatListPage extends StatefulWidget {
  // U2：桌面启动时透传的待发送文件/目录路径（"发送到/打开方式"进入，
  // main.dart 经 LaunchArgs.pendingPaths 解析后注入）。
  final List<String> initialSendPaths;

  const ChatListPage({super.key, this.initialSendPaths = const []});

  @override
  ChatListPageState createState() => ChatListPageState();
}

class ChatListPageState extends State<ChatListPage>
    with WidgetsBindingObserver {
  int _currentIndex = 0;

  // 加载状态
  bool _isLoadingCache = true;
  String? _cacheLoadError;

  // 设备列表（在线 + 缓存的历史设备）
  final List<DeviceInfo> _allDevices = [];
  // E1：在线状态机（peer_presence，在线集合 + legacy 升级编排）。
  late final PeerPresence _presence = PeerPresence(
    onChanged: _scheduleSaveDeviceList,
    onLegacyUpgraded: (oldKey, newKey) {
      // 迁移自动接收配置（原按 IP 键存，E1 走 AutoReceiveStore）
      unawaited(_autoReceiveStore.migrate(oldKey, newKey));
      // 迁移旧 IP 命名的消息缓存文件
      _cacheService.migrateLegacyCache(newKey, oldKey);
    },
  );
  // 在线设备 ID 集合（E1：经 _presence 在线集合读取）。
  Set<String> get _onlineDeviceIds => _presence.onlineIds;

  // UDP 局域网通讯配置（P1-1：首选端口可配置，实际绑定可能探测回退）
  int _preferredUdpPort = UdpMessageService.defaultMsgPort;
  // v2 接收服务首选端口（默认 53317，实际绑定经 _lsServer.boundPort 读取）
  int _preferredTcpPort = kLsDefaultPort;
  // E1：发现/广播机器（socket 生命周期 + 广播目标 + 单播选栈）抽至
  // lan_discovery_service，实际 UDP 端口经 _discovery.udpPort 读取。
  final LanDiscoveryService _discovery = LanDiscoveryService();
  Timer? _broadcastTimer;
  // N4：服务存活看门狗（30s 巡检 UDP/TCP/broadcast，die 则自动重启）。
  Timer? _watchdogTimer;
  // N1：mDNS 兜底发现巡检（8s < 心跳超时 10s，广播被吞时设备不闪断）。
  Timer? _mdnsTimer;
  bool _mdnsScanRunning = false;
  // E1：默认值抽至 chat_defaults（kUnknownIp/kLoadingDeviceName）。
  String _localIP = kUnknownIp;
  String _myDeviceName = kLoadingDeviceName;
  // U2：桌面启动参数待发送（仅消费一次，发现就绪后有在线设备即触发）。
  bool _launchSendConsumed = false;

  // 存储本机的所有合法 IPv4，用于精准防自锁
  final List<String> _localIPList = [];

  // 存储本机所有子网广播地址（用于跨子网广播发现）
  final List<InternetAddress> _subnetBroadcastAddresses = [];

  // 消息服务
  final UdpMessageService _msgService = UdpMessageService();
  final MessageCacheService _cacheService = MessageCacheService();
  // v2 接收服务（LocalSend Protocol v2 HTTPS，53317 起探测回退）
  final LsServer _lsServer = LsServer();
  // v2 组播发现事件订阅（announce → 设备注册表）
  StreamSubscription<LsDiscoveredDevice>? _lsDiscoverySub;
  // 哪些设备的 ChatPage 正在打开（用于避免全局 + ChatPage 双重 file_accept）
  final Set<String> _openChatDeviceIPs = {};
  // U2：桌面端拖拽提示框（desktop_drop，仅桌面平台启用）
  bool _dragging = false;
  bool get _isDesktopPlatform => isDesktopPlatform(
        // E1：抽至 platform_info.isDesktopPlatform。
        isWindows: Platform.isWindows,
        isMacOS: Platform.isMacOS,
        isLinux: Platform.isLinux,
      );

  // 全局消息监听：自动 ACK 文字消息，确保发送方不重试
  StreamSubscription<ReceivedMessage>? _globalMsgSub;
  // U2：从其他 App 分享进来（Android SEND intent）的监听
  StreamSubscription<List<SharedMediaFile>>? _shareSub;
  // 全局拉黑设备 IP 集合（从 blocked_devices.json 加载）
  // E1：配对/拉黑状态抽至 paired_device_store（PairedDeviceStore，TOFU 指纹键）。
  // P0-S2：配对对话框去重（同一指纹同时只弹一次）
  final Set<String> _pairingInProgress = {};
  final PairedDeviceStore _handshake = PairedDeviceStore();
  // 自动接收配置（E1：文件读写抽至 AutoReceiveStore，缺省 false）
  final AutoReceiveStore _autoReceiveStore = AutoReceiveStore();
  // ===== v2 接收管线状态（LocalSend Protocol v2） =====
  // 会话内活跃气泡：键 'sessionId|fileId' → (对端身份键, 气泡消息)，
  // 进度/结果回写与取消清理共用（气泡 id = 'ls_recv_<sessionId>_<fileId>'）。
  final Map<String, ({String peerKey, ChatMessage msg})> _lsLive = {};
  // 挂起的 prepare-upload 决策：键 sessionId → 决策对象（无短超时，
  // 由气泡按钮 / 接收对话框 / 会话结束兜底完成 completer）。
  final Map<String, _LsPendingDecision> _lsPending = {};
  // 进度回写节流时间戳：键 'sessionId|fileId' → 上次回写毫秒。
  final Map<String, int> _lsProgressTicks = {};
  // 已弹过接收确认对话框的会话（防重复弹窗）。
  final Set<String> _lsDialogSessions = {};

  /// P1-3：文字 msgId 去重窗口，避免重试风暴反复读缓存文件（E1 抽至 session_tracker.RecvDedupWindow）
  final RecvDedupWindow _recvDedup = RecvDedupWindow();

  /// P1-T7：文字离线队列 deviceKey -> 待重推文字（发送失败入队，对端上线重推，E1 抽至 offline_text_queue）。
  final OfflineTextQueue _pendingOfflineTexts = OfflineTextQueue();

  // 文件存储路径（用于 UI 显示，实际持久化在 storage_config.json）
  // E1：默认值抽至 chat_defaults.kDefaultStorageLabel。
  String _storagePathLabel = kDefaultStorageLabel;
  // P0-S3：仅TLS传输开关（security_config.json，默认 true）
  bool _tlsOnly = true;
  // S2：接收 PIN（security_config.json 的 receivePin，空=不启用）
  String _receivePin = '';
  // N5：发现可见性三档 all/paired/stealth（默认 all，兼容旧 _stealthMode）。
  // E1：默认值抽至 chat_defaults.kDefaultVisibility。
  String _visibility = kDefaultVisibility;
  // U4 隐身模式：开启后跳过主动广播，仅单播回包（security_config.json）。
  // 保留字段供旧逻辑兼容，权威值以 _visibility 为准。
  bool _stealthMode = false;
  // P1-1：端口被占用回退后给用户一次 toast
  String? _portFallbackHint;

  // 设备列表缓存保存防抖
  Timer? _saveDebounceTimer;

  // 设备列表文件写入锁，防止并发写导致缓存损坏
  Future<void>? _deviceListWriteLock;
  // E1：设备列表落盘（原子写 + 逐条容错读）。
  final DeviceListStore _deviceListStore = DeviceListStore();

  // P1-N1：mDNS 发现（查询可用；发布已接原生 NSD/Bonjour，见 MdnsDiscovery）
  final MdnsDiscovery _mdns = MdnsDiscovery();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // v2：绑定接收服务的 UI 回调（决策/进度/结果/会话结束/对端取消）
    _bindLsServerCallbacks();
    _initDeviceAndNetwork();
    // U2：从其他 App 分享进来（Android SEND intent）
    unawaited(_handleInboundShares());
  }

  // P1-N5：后台暂停广播，前台恢复（前台 3s、后台暂停）
  // N4：前台恢复时同步做一次看门狗巡检（server die 则重启）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // E1：后台暂停判定收敛至 device_tile_meta.shouldPauseBroadcast。
    if (shouldPauseBroadcast(state.name)) {
      _broadcastTimer?.cancel();
      _broadcastTimer = null;
      _watchdogTimer?.cancel();
      _watchdogTimer = null;
      _mdnsTimer?.cancel();
      _mdnsTimer = null;
      debugPrint(pauseBroadcastLog()); // E1：暂停日志纯函数委托
    } else if (isResumedState(state.name)) { // E1：前台判定委托
      // E1：未知判定抽至 chat_defaults.isUnknownIp。
      if (_discovery.isReady && !isUnknownIp(_localIP)) {
        debugPrint(resumeBroadcastLog()); // E1：恢复日志纯函数委托
        _startAdvertising();
      }
      unawaited(_watchdogCheck());
      _startWatchdog();
      unawaited(_mdnsScan());
      _startMdnsScan();
    }
  }

  /// N4：30s 巡检 UDP/TCP/broadcast 存活，die 则重启（对标 LocalSend 自动重启）。
  /// E1：周期抽至 transfer_limits.kWatchdogSec。
  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(
      const Duration(seconds: kWatchdogSec),
      (_) {
        unawaited(_watchdogCheck());
      },
    );
  }

  /// N1：mDNS 兜底发现巡检（8s 周期，< 心跳超时 10s 不闪断）。
  /// E1：周期抽至 transfer_limits.kMdnsScanSec。
  void _startMdnsScan() {
    _mdnsTimer?.cancel();
    _mdnsTimer = Timer.periodic(const Duration(seconds: kMdnsScanSec), (_) {
      unawaited(_mdnsScan());
    });
  }

  /// N1：一轮 mDNS 兜底发现并入设备列表（重入保护）。
  Future<void> _mdnsScan() async {
    if (_mdnsScanRunning) return;
    // E1：未知判定抽至 chat_defaults.isUnknownIp。
    if (!_discovery.isReady || isUnknownIp(_localIP)) return;
    _mdnsScanRunning = true;
    try {
      final devices = await _mdns.discoverDevices();
      for (final d in devices) {
        // E1：自身过滤/设备键抽至 device_lookup。
        if (isSelfMdns(ip: d.ip, localIp: _localIP, localList: _localIPList)) {
          continue;
        }
        final deviceKey = mdnsDeviceKey(deviceId: d.deviceId, ip: d.ip);
        // P0-S2：已拉黑设备忽略。
        // P1-10（对齐 LocalSend）：发现阶段不再弹配对确认框，设备直接可用；
        // 配对改为用户主动操作（设备卡片长按），未配对传输由文件级同意兜底。
        if (_handshake.blocked.contains(deviceKey)) continue;
        _msgService.recordHeartbeat(deviceKey);
        final du = d.udpPort;
        if (isNotNull(du)) { // E1：非空判定委托
          _msgService.rememberPeerUdpPort(d.ip, du!);
        }
        _upsertDevice(
          deviceKey: deviceKey,
          peerIp: d.ip,
          name: d.name,
          type: 'desktop',
          udpPort: resolveMdnsUdpPort( // E1：mDNS端口回退委托
              d.udpPort, UdpMessageService.defaultMsgPort),
          tcpPort: d.port,
          // E1：mDNS 默认文案抽至 device_lookup.mdnsOnlineText。
          lastMsg: mdnsOnlineText(),
        );
      }
    } finally {
      _mdnsScanRunning = false;
    }
  }

  Future<void> _watchdogCheck() async {
    // E1：未知判定抽至 chat_defaults.isUnknownIp。
    if (isUnknownIp(_localIP)) return;
    var restarted = false;
    // E1：广播重启收敛至 device_tile_meta.needsBroadcastRestart。
    if (needsBroadcastRestart(
      isNull: _broadcastTimer == null,
      // E1：活跃判定委托。
      isActive: isBroadcastActive(
          hasTimer: _broadcastTimer != null,
          isActive: _broadcastTimer?.isActive ?? false),
    )) {
      debugPrint(watchdogBroadcastLog()); // E1：看门狗广播日志委托
      _startAdvertising();
      restarted = true;
    }
    if (!_lsServer.isRunning) {
      debugPrint(watchdogTcpLog()); // E1：看门狗TCP日志委托
      try {
        await _lsServer.start(preferredPort: _preferredTcpPort);
        restarted = true;
      } catch (e) {
        debugPrint(watchdogTcpFailLog(e)); // E1：看门狗TCP失败日志委托
      }
    }
    if (restarted && mounted) {
      debugPrint(watchdogDoneLog()); // E1：看门狗完成日志委托
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _mdns.stop();
    _broadcastTimer?.cancel();
    _watchdogTimer?.cancel();
    _mdnsTimer?.cancel();
    _shareSub?.cancel();
    _saveDebounceTimer?.cancel();
    // E3：退出前把延迟中的消息缓存写完。
    unawaited(_cacheService.flushPending());
    _globalMsgSub?.cancel();
    // v2：停止组播发现与接收服务
    _lsDiscoverySub?.cancel();
    LsDiscovery.instance.stop();
    _lsServer.stop();
    // 确保最后一次保存完成
    _saveCachedDeviceListImmediate();
    // E1：socket 生命周期抽至 lan_discovery_service。
    _discovery.stop();
    super.dispose();
  }

  // E1：_bindUdpWithProbe/_bindUdpV6/_closeUdpSocket 已移至
  // lan_discovery_service（socket 生命周期 + 广播目标 + 单播选栈）。

  // ================= 初始化入口：设备名与网络发现 =================
  // 四个初始化任务互不依赖，并行执行以加速首次设备发现
  Future<void> _initDeviceAndNetwork() async {
    // P1-1：端口配置必须先于发现绑定，否则会用默认 8888/8899 覆盖用户设置
    await Future.wait([
      _fetchRealDeviceName(),
      _loadCachedDevices(),
      // E1：配对/拉黑读写抽至 paired_device_store（一次加载两集合）。
      _handshake.load(),
      _loadTlsOnly(),
      _loadReceivePin(),
      _loadVisibility(),
      _loadStealthMode(),
      _loadStoragePath(),
      _loadAutoReceiveConfig(),
    ]);
    await _initLanDiscovery();
  }

  // 加载缓存设备列表
  Future<void> _loadCachedDevices() async {
    try {
      final cachedDevices = await _readCachedDeviceList();
      // E1：缓存日志收敛至 chat_list_texts.cacheLoadedLog。
      debugPrint(cacheLoadedLog(cachedDevices.length)); // E1：缓存加载日志委托
      if (mounted) {
        setState(() {
          _isLoadingCache = false;
          for (final d in cachedDevices) {
            if (!containsId(_allDevices, (e) => e.id, d.id)) {
              _allDevices.add(d);
              debugPrint(cacheDeviceLog(d.name, d.id)); // E1：缓存设备日志委托
            }
          }
        });
      }
    } catch (e) {
      debugPrint(cacheLoadFailLog(e)); // E1：缓存失败日志委托
      if (mounted) {
        setState(() {
          _isLoadingCache = false;
          _cacheLoadError = e.toString();
        });
      }
    }
  }

  // 保存设备列表到本地缓存（带防抖，避免高频写入）
  // E1：防抖抽至 transfer_limits.kCacheSaveDebounceMs。
  void _scheduleSaveDeviceList() {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = Timer(
      const Duration(milliseconds: kCacheSaveDebounceMs),
      () {
        _saveCachedDeviceListImmediate();
      },
    );
  }

  Future<void> _saveCachedDeviceListImmediate() async {
    // 串行化写入，防止并发写导致缓存损坏
    final previous = _deviceListWriteLock;
    final future = _deviceListStore.save(List.of(_allDevices));
    _deviceListWriteLock = future;
    // E1：待写串行收敛至 session_tracker.hasPendingWrite。
    if (hasPendingWrite(previous)) {
      await previous; // 等待上一次写入完成
    }
    await future;
  }

  // E1：设备列表读写已移至 DeviceListStore。
  Future<List<DeviceInfo>> _readCachedDeviceList() => _deviceListStore.load();

  // ========== P0-S2：首次配对（E1：状态抽至 paired_device_store，对话框 UI 抽至 pairing_dialog） ==========

  /// 检查指定设备是否被拉黑（实时从文件读取，确保与 ChatPage 同步）。
  /// P0-7：黑名单按身份键（deviceId）存储；同时匹配 IP 以兼容 legacy 条目。
  /// 文件损坏时回退内存缓存。
  Future<bool> _checkIpBlocked(String ip, {String? deviceId}) async {
    final list = await _handshake.reloadBlocked();
    return dkr.isBlockedEntry(list, ip, deviceId);
  }

  /// P1-10（对齐 LocalSend）：配对改为用户主动操作——设备卡片长按触发。
  /// 自动发现不再弹窗，设备未配对也可传输（由文件级同意兜底）。
  /// 非 64 位 hex 指纹（旧端 IP 键）不支持配对；已配对/已拉黑给出提示。
  void _promptPairing(String deviceKey, String name) {
    if (!LanUtils.isFingerprintKey(deviceKey)) return;
    if (_handshake.paired.contains(deviceKey)) {
      if (mounted) showCenterToast(context, pairingAlreadyText(name));
      return;
    }
    if (_handshake.blocked.contains(deviceKey)) {
      if (mounted) showCenterToast(context, pairingBlockedHintText(name));
      return;
    }
    // E1：门控抽至 device_lookup.shouldShowPairing（此处仅防并发重复弹窗）。
    if (!shouldShowPairing(
      isFingerprintKey: true,
      paired: false,
      blocked: false,
      inProgress: _pairingInProgress.contains(deviceKey),
    )) {
      return;
    }
    if (!mounted) return;
    _pairingInProgress.add(deviceKey);
    showPairingDialog(context, deviceKey, name, title: pairingManualTitle()).then((trusted) {
      _pairingInProgress.remove(deviceKey);
      // E1：配对结果收敛至 pairing_texts.isTrustedResult/isRejectedResult。
      if (isTrustedResult(trusted)) {
        _handshake.trust(deviceKey);
        unawaited(_handshake.savePaired());
        debugPrint(pairedLog(name)); // E1：配对日志委托
        if (mounted) showCenterToast(context, pairTrustedText(name));
      } else if (isRejectedResult(trusted)) {
        _handshake.block(deviceKey);
        unawaited(_handshake.saveBlocked());
        debugPrint(blockedNewLog(name)); // E1：拉黑日志委托
        if (mounted) {
          setState(() {
            // E1：设备键匹配收敛至 device_merge.matchesDeviceKey。
            _allDevices.removeWhere((d) => matchesDeviceKey(d.id, deviceKey));
            _presence.markOffline(deviceKey);
          });
          showCenterToast(context, pairBlockedText(name));
        }
      }
    });
  }

  // ========== 自动接收配置（E1：文件读写抽至 AutoReceiveStore） ==========

  /// 加载自动接收配置（按设备 IP 索引，缺省 false，P0-S7）
  Future<void> _loadAutoReceiveConfig() async {
    await _autoReceiveStore.load();
    debugPrint(autoReceiveLoadedLog(_autoReceiveStore.config)); // E1：自动接收日志委托
  }

  /// 获取指定设备的自动接收状态（缺省 false，P0-S7；已显式配置的值不变）
  bool _getAutoReceive(String deviceIp) => _autoReceiveStore.get(deviceIp);

  /// 设置指定设备的自动接收状态并持久化
  Future<void> _setAutoReceive(String deviceIp, bool value) async {
    await _autoReceiveStore.set(deviceIp, value);
    debugPrint(autoReceiveSavedLog(deviceIp, value)); // E1：自动接收保存日志委托
  }

  // ================= v2 接收管线（LocalSend Protocol v2） =================
  // 对齐官方接收流程：prepare-upload 挂起等用户决策（无短超时）→
  // 逐文件 upload 进度回写 → 会话结束统一清理。
  // 旧 file_notify / file_accept / 裸 TCP 握手已整体移除，由本分节取代。

  /// v2：绑定接收服务的 UI 回调（initState 调用一次）。
  void _bindLsServerCallbacks() {
    _lsServer.receivePinProvider = () async => _receivePin;
    _lsServer.selfInfo = _buildLsSelfInfo;
    _lsServer.onPrepareUpload = _handleLsPrepareUpload;
    _lsServer.onFileProgress = _onLsFileProgress;
    _lsServer.onFileResult = _onLsFileResult;
    _lsServer.onSessionEnd = _onLsSessionEnd;
    _lsServer.onCancelReceived = _onLsCancelReceived;
    // register 反向发现：对端发现本端并登记时，把对端加入设备流
    // （iOS 无组播 entitlement，收不到组播/广播 announce 的兜底通路）
    _lsServer.onRegisterReceived = (peer, ip) =>
        LsDiscovery.instance.noteRegisterPeer(peer, ip);
  }

  /// v2：本端设备信息（announce / register / info 共用；
  /// port = 本端 v2 HTTPS 服务实际绑定端口）。
  LsDeviceDto _buildLsSelfInfo() => LsDeviceDto(
        alias: _myDeviceName,
        fingerprint: TlsIdentityService.instance.fingerprint,
        port: _lsServer.boundPort,
        download: true,
      );

  /// v2：对端身份键——优先 TLS/自报指纹（v2 恒为指纹键），
  /// 对端未带指纹时回退 IP 反查（兼容旧端）。
  String _lsPeerKeyOf(LsIncomingRequest request) {
    final fp = request.trustedFingerprint;
    if (fp.isNotEmpty) return fp;
    return _deviceKeyOf(request.senderIp);
  }

  /// v2：磁盘空间预检（替代旧裸 TCP 服务的 precheckSpace）。
  /// 剩余空间 ≤ 文件总大小 + 1MB 返回 'noSpace'；拿不到剩余空间保守放行。
  Future<String?> _lsSpaceOk(int totalSize) async {
    try {
      // E1：存储落盘路径回退委托（默认标签 → 应用文档目录）。
      final free = await FreeSpace.of(resolveStorageSavePath(_storagePathLabel));
      if (free == null) return null;
      if (free <= totalSize + 1024 * 1024) return 'noSpace';
    } catch (_) {}
    return null;
  }

  /// v2：prepare-upload 入口（接收决策管线，判定顺序）：
  /// ① 拉黑 → 直接拒绝；② fileMeta 旁路取元数据；③ 自动接收 →
  /// 空间预检通过即整会话接受；④ ChatPage 打开 → 挂起等气泡按钮；
  /// ⑤ 其余 → 弹接收确认对话框。④⑤均挂起等用户（无短超时，
  /// 发送方断开由 onSessionEnd(aborted) 兜底完成决策防泄漏）。
  Future<LsPrepareDecision> _handleLsPrepareUpload(
    LsIncomingRequest request,
  ) async {
    final peerKey = _lsPeerKeyOf(request);
    final firstFile = request.files.values.isEmpty
        ? null
        : request.files.values.first;
    final fileName = firstFile?.fileName ?? '';
    // ① 拉黑 → 直接拒绝（不建气泡，403）
    if (await _checkIpBlocked(request.senderIp, deviceId: peerKey)) {
      debugPrint(fileRejectedLog(fileName, 'blocked')); // E1：拒绝日志委托
      return const LsDecline();
    }
    // ② fileMeta 旁路取元数据（UDP 8888 一次消费；语音/文件夹展示信息）。
    // 官方 LocalSend 发来的没有 meta → 全空，按普通文件气泡处理。
    final metas = <String, FileMeta>{};
    var totalSize = 0;
    for (final f in request.files.values) {
      totalSize += f.size;
      final m =
          _msgService.fileMetaCache.take(fileMetaKey(f.fileName, f.size));
      if (m != null) metas[f.id] = m;
    }
    // ③ 自动接收 → 空间预检通过即整会话接受（直接进传输中，无需确认）
    if (_getAutoReceive(peerKey)) {
      final noSpace = await _lsSpaceOk(totalSize);
      if (noSpace == null) {
        debugPrint(fileAcceptedLog(fileName, 0, totalSize)); // E1：接受日志委托
        await _createLsBubbles(request, peerKey, metas, accepted: true);
        return LsAccept(request.files.keys.toSet());
      }
      if (mounted) showCenterToast(context, noSpaceReceiveText(fileName));
      debugPrint(fileRejectedLog(fileName, noSpace)); // E1：拒绝日志委托
      return const LsDecline();
    }
    // ④⑤ 挂起等用户：逐文件建 pending 气泡；ChatPage 打开 → 气泡按钮决策，
    // 未打开 → 弹接收确认对话框。决策经 completer 回流，本 Future 保持未完成。
    debugPrint(
        '[ChatList] v2 等待用户决策: $fileName (${request.files.length} 文件, peer=$peerKey)');
    final decision = _LsPendingDecision(request, peerKey);
    _lsPending[request.sessionId] = decision;
    await _createLsBubbles(request, peerKey, metas, accepted: false);
    if (mounted && !_openChatDeviceIPs.contains(peerKey)) {
      _showLsReceiveDialog(decision);
    }
    return decision.completer.future;
  }

  /// v2：为会话逐文件创建接收气泡并推送（一个会话多文件 = 多个气泡，
  /// id = 'ls_recv_{sessionId}_{fileId}' 确定性可回写）。
  /// [accepted] = 自动接受：直接进传输中；否则 pending 等用户决策。
  Future<void> _createLsBubbles(
    LsIncomingRequest request,
    String peerKey,
    Map<String, FileMeta> metas, {
    required bool accepted,
  }) async {
    final total = request.files.length;
    var index = 0;
    for (final f in request.files.values) {
      index++;
      final meta = metas[f.id];
      final isVoice = meta?.isVoice ?? false;
      final isFolder = meta?.isFolder ?? false;
      // 批量会话展示"第 i/n 个"后缀，单文件不展示。
      final batchSuffix =
          total > 1 ? batchCountSuffix(request.sessionId, total, index) : '';
      final msg = buildInboundPending(
        pendingId: 'ls_recv_${request.sessionId}_${f.id}',
        senderIp: request.senderIp,
        // E1：标签/内容抽至 send_waiting_texts（与旧 pending 气泡同款文案）。
        content: buildPendingContent(
          label: pendingLabel(isFolder: isFolder),
          fileName: f.fileName,
          batchSuffix: batchSuffix,
        ),
        isVoice: isVoice,
        fileName: f.fileName,
        fileSizeText: formatFileSize(f.size),
        isFolder: isFolder,
        transferId: null,
        sessionId: request.sessionId,
        durationMs: meta?.durationMs ?? 0,
        waveformData: meta?.waveformData,
        now: now() /* E1: clock->app_clock.now */,
      );
      // 自动接受：pending → transferring（等待上传进度回写）
      final bubble = accepted
          ? msg.copyWith(
              transferState: TransferState.transferring,
              progress: 0.0,
            )
          : msg;
      _lsLive['${request.sessionId}|${f.id}'] = (peerKey: peerKey, msg: bubble);
      await _writeLsBubble(peerKey, bubble, isNew: true);
    }
  }

  /// v2：ChatPage 未打开时的接收确认对话框（整会话一次决策，
  /// 选择结果完成挂起的 completer；与旧 _showReceiveDialog 同款 UI）。
  void _showLsReceiveDialog(_LsPendingDecision pending) {
    if (_lsDialogSessions.contains(pending.request.sessionId)) return;
    _lsDialogSessions.add(pending.request.sessionId);
    final files = pending.request.files.values.toList();
    final fileName = files.isEmpty ? '' : files.first.fileName;
    final totalSize = files.fold<int>(0, (s, f) => s + f.size);
    final total = files.length;
    final isFolder = files.any((f) => false); // 文件夹在 v2 载荷无标记，按文件展示
    // E1：名回退抽至 device_lookup.resolveDeviceDisplayName（纯函数可单测）。
    final deviceName = resolveDeviceDisplayName(
      [for (final d in _allDevices) (id: d.id, name: d.name)],
      pending.peerKey,
      pending.request.senderIp,
    );
    // E1：尺寸后缀抽至 file_size_format.formatSizeSuffix（纯函数可单测）。
    final sizeStr = formatSizeSuffix(totalSize, formatFileSize);
    // E1：标题/文件名行/批量判定抽至 receive_dialog_texts（纯函数可单测）。
    final isBatch = isBatchReceive(pending.request.sessionId, total);
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(receiveDialogTitle(
          notifyToastLabel(isFolder),
          pending.request.sessionId,
          total,
        )),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              receiveFromText(deviceName),
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 6),
            Text(
              receiveDialogFileLine(fileName, pending.request.sessionId, total),
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            if (totalSize > 0) ...[
              const SizedBox(height: 4),
              Text(
                sizeStr,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
            if (isBatch)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  batchHintText(),
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: Text(receiveRejectText()),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.green),
            child: Text(receiveAcceptText()),
          ),
        ],
      ),
    ).then((accepted) {
      // E1：弹窗结果收敛至 arrival_texts.isDialogAccepted/isExplicitReject。
      if (isDialogAccepted(accepted)) {
        _acceptLsPending(pending.request.sessionId);
      } else if (isExplicitReject(accepted)) {
        _declineLsPending(pending.request.sessionId);
      }
    });
  }

  /// v2：完成挂起决策——整会话接受（气泡 pending → transferring 等待上传）。
  void _acceptLsPending(String? sessionId) {
    final pending = _takeLsPending(sessionId);
    if (pending == null) return;
    if (!pending.completer.isCompleted) {
      pending.completer.complete(LsAccept(pending.request.files.keys.toSet()));
    }
    // 气泡 pending → transferring；缓存与打开中的 ChatPage 同步回写
    for (final f in pending.request.files.values) {
      final key = '${pending.request.sessionId}|${f.id}';
      final live = _lsLive[key];
      if (live == null) continue;
      final updated = live.msg.copyWith(
        // E1：文案抽至 TransferTexts.waitingContent。
        content: TransferTexts.waitingContent(fileNameOrEmpty(live.msg.fileName)),
        transferState: TransferState.transferring,
        progress: 0.0,
      );
      _lsLive[key] = (peerKey: live.peerKey, msg: updated);
      unawaited(_writeLsBubble(live.peerKey, updated, isNew: false));
    }
  }

  /// v2：完成挂起决策——整会话拒绝（气泡 pending → failed 已拒绝）。
  void _declineLsPending(String? sessionId) {
    final pending = _takeLsPending(sessionId);
    if (pending == null) return;
    if (!pending.completer.isCompleted) {
      pending.completer.complete(const LsDecline());
    }
    for (final f in pending.request.files.values) {
      final key = '${pending.request.sessionId}|${f.id}';
      final live = _lsLive.remove(key);
      if (live == null) continue;
      // E1：失败变异/文案收敛至 TransferTexts.markSelfReject/selfRejectContent。
      final updated = TransferTexts.markSelfReject(
        live.msg,
        TransferTexts.selfRejectContent(fileNameOrEmpty(live.msg.fileName)),
      );
      unawaited(_writeLsBubble(live.peerKey, updated, isNew: false));
    }
  }

  /// v2：取出挂起决策（一次消费；无在途决策返回 null = 调用方 no-op）。
  _LsPendingDecision? _takeLsPending(String? sessionId) {
    if (sessionId == null || sessionId.isEmpty) return null;
    return _lsPending.remove(sessionId);
  }

  /// v2：接收气泡统一出口——写缓存 + 推送打开中的 ChatPage（静态 hook）。
  /// [isNew] = true 追加新气泡 / false 原位替换回写。
  Future<void> _writeLsBubble(
    String deviceKey,
    ChatMessage msg, {
    required bool isNew,
  }) async {
    // E1：缓存迁移判定委托（legacy IP 键升级时迁移缓存文件）。
    if (needsCacheMigrate(deviceKey, msg.senderId)) {
      _cacheService.migrateLegacyCache(deviceKey, msg.senderId);
    }
    if (isNew) {
      await _cacheService.appendMessage(deviceKey, msg);
    } else {
      await _cacheService.updateMessage(deviceKey, msg.id, msg);
    }
    ChatPage.incomingFileHooks[deviceKey]?.call(msg, isNew);
  }

  /// v2：单文件上传进度回调（服务端未节流，此处节流后回写气泡）。
  void _onLsFileProgress(String sessionId, String fileId, int received, int total) {
    final key = '$sessionId|$fileId';
    final live = _lsLive[key];
    if (live == null) return;
    // E1：节流判定抽至 text_retry_policy.shouldThrottleProgress。
    final tick = nowMs();
    if (shouldThrottleProgress(
      lastTickMs: _lsProgressTicks[key] ?? 0,
      nowMs: tick,
    )) {
      return;
    }
    _lsProgressTicks[key] = tick;
    // 语音气泡保持原"语音消息"内容，仅回写进度/状态
    final updated = live.msg.copyWith(
      progress: total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0,
      transferState: TransferState.transferring,
    );
    _lsLive[key] = (peerKey: live.peerKey, msg: updated);
    unawaited(_writeLsBubble(live.peerKey, updated, isNew: false));
  }

  /// v2：单文件落盘完成/失败回调：气泡回写终态（缓存 + 打开中的 ChatPage）。
  Future<void> _onLsFileResult(LsFileResult result) async {
    final key = '${result.sessionId}|${result.fileId}';
    final live = _lsLive.remove(key);
    _lsProgressTicks.remove(key);
    if (live == null) return;
    final old = live.msg;
    // 终态保护：已 completed/failed 的气泡不再回退。
    if (shouldGuardTerminal(old.transferState)) return;
    final fileName = fileNameOrEmpty(old.fileName);
    final ChatMessage updated;
    if (result.success) {
      updated = old.copyWith(
        // E1：结果文案抽至 TransferTexts.globalProgressContent（音频恒"语音消息"）。
        content: TransferTexts.globalProgressContent(
          isAudio: isAudioMessageType(old.type.name),
          isSuccess: true,
          isFolder: old.isFolder,
          fileName: fileName,
        ),
        transferState: TransferState.completed,
        progress: 1.0,
        filePath: result.savedPath ?? old.filePath,
        // 图片：回填落盘路径供缩略图/预览生成
        imagePath: isImageMessageType(old.type.name)
            ? (result.savedPath ?? old.imagePath)
            : old.imagePath,
      );
      // 到达 toast（对齐旧 TCP 到达提示）
      if (mounted) {
        final deviceName = resolveDeviceDisplayName(
          [for (final d in _allDevices) (id: d.id, name: d.name)],
          live.peerKey,
          old.senderId,
        );
        showCenterToast(
          context,
          arrivalToastText(
            label: arrivalLabel(old.isFolder),
            deviceName: deviceName,
            fileName: fileName,
          ),
        );
      }
    } else {
      updated = old.copyWith(
        content: TransferTexts.globalProgressContent(
          isAudio: isAudioMessageType(old.type.name),
          isSuccess: false,
          isFolder: old.isFolder,
          fileName: fileName,
        ),
        transferState: TransferState.failed,
        progress: 0.0,
      );
    }
    await _writeLsBubble(live.peerKey, updated, isNew: false);
  }

  /// v2：会话结束回调。finished = 全部文件到终态（气泡已各自回写）；
  /// cancelled/aborted = 发送方取消/断开：挂起决策兜底完成（拒绝）+
  /// 活跃气泡统一标记对端取消。
  void _onLsSessionEnd(String sessionId, LsSessionEndReason reason) {
    debugPrint('[ChatList] v2 会话结束: $sessionId ($reason)');
    _lsDialogSessions.remove(sessionId);
    if (reason == LsSessionEndReason.finished) return;
    // 挂起决策兜底完成，防 completer 泄漏（发送方断开时无其他完成路径）
    final pending = _lsPending.remove(sessionId);
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.complete(const LsDecline());
    }
    unawaited(_markLsSessionCancelled(sessionId));
  }

  /// v2：会话被发送方取消/中断——活跃气泡 → failed（对端取消文案）。
  Future<void> _markLsSessionCancelled(String sessionId) async {
    final keys =
        _lsLive.keys.where((k) => k.startsWith('$sessionId|')).toList();
    for (final key in keys) {
      final live = _lsLive.remove(key);
      _lsProgressTicks.remove(key);
      if (live == null) continue;
      // 终态保护：已 completed/failed 的气泡不被取消覆盖。
      if (shouldGuardTerminal(live.msg.transferState)) continue;
      // E1：失败变异/文案收敛至 TransferTexts.markPeerCancel/cancel_texts。
      final updated = TransferTexts.markPeerCancel(
        live.msg,
        peerCancelContent(
          isAudio: isAudioMessageType(live.msg.type.name),
          isMe: live.msg.isMe,
          fileName: fileNameOrEmpty(live.msg.fileName),
        ),
      );
      await _writeLsBubble(live.peerKey, updated, isNew: false);
    }
  }

  /// v2：收到未知会话的 cancel = 对端取消"我们正在发送"的会话。
  /// 按 IP 反查身份键：打开中的 ChatPage 即时更新气泡并中止本地请求；
  /// 未打开时直接修缓存，避免发送气泡永远停在"发送中"。
  Future<void> _onLsCancelReceived(String ip, String sessionId) async {
    final peerKey = _deviceKeyOf(ip);
    debugPrint('[ChatList] 对端取消发送会话: $peerKey / $sessionId');
    ChatPage.cancelSendHooks[peerKey]?.call(sessionId);
    // ChatPage 未打开时 hook 不存在：直接修缓存（已终态的消息守卫跳过）
    final cached = await _cacheService.loadMessages(peerKey);
    for (final m in cached) {
      if (m.sessionId != sessionId ||
          !m.isMe ||
          !isCancelActiveState(m.transferState) ||
          shouldGuardTerminal(m.transferState)) {
        continue;
      }
      // E1：失败变异/文案收敛至 TransferTexts.markPeerCancel/cancel_texts。
      await _cacheService.updateMessage(
        peerKey,
        m.id,
        TransferTexts.markPeerCancel(
          m,
          peerCancelContent(
            isAudio: isAudioMessageType(m.type.name),
            isMe: m.isMe,
            fileName: fileNameOrEmpty(m.fileName),
          ),
        ),
      );
    }
  }

  /// v2：组播发现事件 → 设备注册表（按指纹合并；deviceId 即指纹，
  /// 与 legacy 广播发现天然合并到同一设备条目）。
  void _onLsDeviceDiscovered(LsDiscoveredDevice d) {
    // 自端回环过滤（发现服务已过滤，此处双保险）
    if (_localIPList.contains(d.ip)) return;
    if (_handshake.blocked.contains(d.fingerprint)) return; // 已拉黑忽略
    _msgService.recordHeartbeat(d.fingerprint);
    // 已有条目保留其 legacy UDP 端口（单播心跳通道），仅新建时用默认端口兜底
    final existing =
        _allDevices.firstWhereOrNull((dev) => dev.id == d.fingerprint);
    _upsertDevice(
      deviceKey: d.fingerprint,
      peerIp: d.ip,
      name: d.alias,
      type: d.deviceType ?? 'desktop',
      udpPort: existing?.udpPort ?? UdpMessageService.defaultMsgPort,
      // v2 发现携带的 port = 对端 HTTPS 服务端口（ChatPage 发送目标）
      tcpPort: d.port,
      // E1：mDNS 默认文案抽至 device_lookup.mdnsOnlineText。
      lastMsg: mdnsOnlineText(),
    );
  }

  /// ChatPage 用户点击手动接收文件的回调（v2：完成对应会话的挂起决策）。
  /// [deviceKey] 为对端身份键；[sessionId] = v2 会话 ID，
  /// 无在途决策（如"请求对方重发"按钮）时为 no-op。
  Future<void> _onUserManualAcceptFile(
    String deviceKey,
    String fileName,
    String? transferId, {
    String? sessionId,
  }) async {
    debugPrint(manualAcceptLog(fileName, deviceKey)); // E1：手动同意日志委托
    // v2：完成挂起的 prepare-upload 决策（接受整会话），
    // 气泡状态由进度/结果回调回写
    _acceptLsPending(sessionId);
  }

  /// 用户手动拒绝接收文件（来自 ChatPage 按钮；v2：完成对应会话的挂起决策）。
  void _onUserManualRejectFile(
    String deviceKey,
    String fileName,
    String? transferId, {
    String? sessionId,
  }) {
    debugPrint(manualRejectLog(fileName, deviceKey)); // E1：手动拒绝日志委托
    // v2：完成挂起的 prepare-upload 决策（拒绝整会话），气泡标记已拒绝
    _declineLsPending(sessionId);
  }

  // 💡 动态获取真实设备名称（E1：探测抽至 Services/device_name.dart）
  Future<void> _fetchRealDeviceName() async {
    final detectedName = await detectDeviceName();
    if (mounted) {
      setState(() {
        _myDeviceName = detectedName;
      });
    }
  }

  // ================= 局域网真实扫描与广播核心逻辑 =================
  Future<void> _initLanDiscovery() async {
    // E1：socket 关闭抽至 lan_discovery_service。
    _discovery.stop();
    // N1：重启发现时撤销旧 mDNS 注册，稍后按新端口重发。
    await _mdns.unpublish();

    try {
      String? wifiIP;
      final List<String> allValidIPs = [];
      _localIPList.clear();

      // 1. 优先尝试通过网络库获取 Wi-Fi IP
      try {
        final info = NetworkInfo();
        wifiIP = await info.getWifiIP();
        // E1：Wi-Fi IP 可用判定收敛至 local_ip_picker.isUsableWifiIp。
        if (isUsableWifiIp(wifiIP)) {
          _localIPList.add(wifiIP!);
          allValidIPs.add(wifiIP);
          debugPrint(wifiIpLog(wifiIP)); // E1：WiFi IP日志委托
        }
      } catch (_) {}

      // 2. 遍历底层所有物理网卡（E1：枚举抽至 LanUtils.enumerateInterfaces，
      // P1-N2：同时收集 IPv6 ULA/link-local；v4/v6 带接口名，广播按掩码或 /24 回退）
      final scan = await enumerateInterfaces();
      for (final entry in scan.v6Private) {
        if (!_localIPList.contains(entry.ip)) {
          _localIPList.add(entry.ip);
          debugPrint(nicV6Log(entry.name, entry.ip)); // E1：网卡IPv6日志委托
        }
      }
      for (final entry in scan.v4Private) {
        if (!_localIPList.contains(entry.ip)) {
          _localIPList.add(entry.ip);
          allValidIPs.add(entry.ip);
          debugPrint(nicV4Log(entry.name, entry.ip)); // E1：网卡IP日志委托
        }
      }
      for (final bcAddr in scan.subnetBroadcasts) {
        // E1：广播地址比对委托。
        if (!_subnetBroadcastAddresses.any(
          (a) => sameBroadcast(a.address, bcAddr.address),
        )) {
          _subnetBroadcastAddresses.add(bcAddr);
        }
      }

      // P1-2：广播地址已在上面按接口掩码获取，此处无需再遍历 allValidIPs

      // E1：主 IP 优选抽至 local_ip_picker.pickLocalIp（纯函数可单测）。
      final selectedIP = pickLocalIp(wifiIp: wifiIP, v4Ips: allValidIPs);

      // E1：本地 IP 缺失收敛至 device_tile_meta.hasNoLocalIp。
      if (hasNoLocalIp(selectedIP)) {
        debugPrint(noLocalIpLog()); // E1：无本地IP日志委托
        setState(() {
          // E1：占位抽至 chat_defaults.kUnknownIp。
          _localIP = kUnknownIp;
        });
        return;
      }

      debugPrint(selectedIpLog(selectedIP, _localIPList)); // E1：主IP选择日志委托

      setState(() {
        _localIP = selectedIP!;
      });

      // 清理 _allDevices 中因历史 bug 产生的无效 ID（空字符串或 0.0.0.0）
      // 这些条目会导致 ChatPage 无法正确过滤消息，进而无法解压/缓存
      // E1：谓词抽至 device_tile_meta.isInvalidDeviceId，计数/移除收敛至 device_merge。
      final invalidCount =
          countInvalidDevices(_allDevices, (d) => isInvalidDeviceId(d.id));
      if (invalidCount > 0) {
        removeInvalidDevices(_allDevices, (d) => isInvalidDeviceId(d.id));
        debugPrint(deviceCleanupLog(invalidCount)); // E1：无效设备清理日志委托
        _scheduleSaveDeviceList();
      }

      // P1-1/N2/E1：绑定 UDP 首选端口（探测回退）+ 组播 + v6 双栈 +
      // v4/v6 共用收包回调，全部抽至 lan_discovery_service。
      await _discovery.start(
        preferredPort: _preferredUdpPort,
        localIPs: _localIPList,
        onDatagram: (rawData, senderIp, srcPort) {
          _handleIncomingBroadcast(rawData, senderIp, srcPort);
          _msgService.rememberPeerUdpPort(senderIp, srcPort);
          _msgService.handleRawData(rawData, senderIp);
        },
      );
      // E1：UDP 回退门控收敛至 device_lookup.needsUdpFallbackHint。
      if (needsUdpFallbackHint(_discovery.udpPort, _preferredUdpPort)) {
        // E1：文案抽至 device_lookup.udpFallbackText。
        _portFallbackHint = udpFallbackText(
          _preferredUdpPort,
          _discovery.udpPort,
        );
      }

      _msgService.attachToExisting(_discovery.socket!, _localIP);

      // P1-N1：启动 mDNS client（查询监听）；TCP 端口确定后原生发布（NSD/Bonjour）。
      unawaited(_mdns.startAnnounce());

      // P1-1：启动 v2 HTTPS 接收服务（LocalSend Protocol v2，53317 起探测回退）
      try {
        await _lsServer.start(preferredPort: _preferredTcpPort);
        // E1：TCP回退判定委托。
        if (isTcpFallback(_lsServer.boundPort, _preferredTcpPort)) {
          // E1：文案抽至 device_lookup.tcpFallbackText/joinFallback。
          final tcpHint = tcpFallbackText(_preferredTcpPort, _lsServer.boundPort);
          _portFallbackHint = joinFallback(_portFallbackHint, tcpHint);
        }
        // N1：按实际 TCP 端口发布 `_wlt._tcp`（Android NSD / iOS Bonjour，桌面 no-op）。
        unawaited(
          _mdns.publishAnnounce(
            name: _myDeviceName,
            port: _lsServer.boundPort,
            deviceId: TlsIdentityService.instance.deviceId,
            udpPort: _discovery.udpPort,
          ),
        );
      } catch (e, s) {
        debugPrint(tcpStartFailLog(e)); // E1：TCP启动失败日志委托
        debugPrint('[ChatList] v2 TCP 启动失败堆栈:\n$s');
        if (mounted) {
          showCenterToast(context, tcpStartFailText());
        }
      }

      // v2：启动组播发现（UDP 53317 组播 + 广播，突发 announce + 3s 周期）。
      // 需在 _lsServer.start 之后：announce 携带的端口取 _lsServer.boundPort。
      LsDiscovery.instance.extraBroadcastTargets =
          List.of(_subnetBroadcastAddresses);
      LsDiscovery.instance.selfInfo = _buildLsSelfInfo;
      _lsDiscoverySub?.cancel();
      _lsDiscoverySub =
          LsDiscovery.instance.stream.listen(_onLsDeviceDiscovered);
      try {
        await LsDiscovery.instance.start();
      } catch (e) {
        debugPrint('[ChatList] v2 组播发现启动失败（仅 legacy 广播可用）: $e');
      }
      // E1：回退提示门控/断言收敛至 text_inbound.hasFallbackHint/requireNonNullHint。
      if (hasFallbackHint(_portFallbackHint) && mounted) {
        showCenterToast(context, requireNonNullHint(_portFallbackHint));
        _portFallbackHint = null;
      }

      // v2：旧 _globalFileSub/_globalProgressSub（裸 TCP newTask/progress）
      // 已移除 —— 文件到达/进度/结果统一由 LsServer 回调处理后经静态 hook 推送。

      // 全局消息监听：对文字消息自动回 ACK 且写入缓存，确保发送方不重试
      // 拉黑设备回 blocked: true，让发送方知道被拉黑并显示提示气泡
      _globalMsgSub?.cancel();
      _globalMsgSub = _msgService.messageStream.listen((msg) async {
        // v2：旧 file_cancel 处理块已移除 —— 发送会话取消由
        // LsServer.onCancelReceived 回调处理（对端 HTTP /cancel）。
        // E1：cmd判定收敛至 text_inbound.isBlockSyncCmd。
        if (isBlockSyncCmd(msg.cmd.name)) {
          // 收到拉黑状态同步：更新设备标记并弹提示
          // E1：blocked 载荷收敛至 text_inbound.parseBlockedPayload。
          final blocked = parseBlockedPayload(msg.payload);
          // P0-7：按身份键定位设备
          final peerKey = _deviceKeyOf(msg.senderIp, msg.payload);
          debugPrint(blockSyncLog(msg.senderIp, peerKey, blocked)); // E1：blockSync日志委托
          if (mounted) {
            setState(() {
              final idx = findFirstIndexById(_allDevices, (d) => d.id, peerKey);
              if (hasFoundIndex(idx)) /* E1：命中委托 */ {
                _allDevices[idx].isBlockedByPeer = blocked;
              }
            });
            if (blocked) {
              // E1：名回退抽至 device_lookup.resolveDeviceDisplayName。
              final name = resolveDeviceDisplayName(
                [for (final d in _allDevices) (id: d.id, name: d.name)],
                peerKey,
                msg.senderIp,
              );
              showCenterToast(context, blockedByNameText(name));
            }
          }
          return;
        }
        // v2：旧 file_notify 接收决策管线已移除 —— 接收统一走
        // LsServer.onPrepareUpload（HTTPS prepare-upload 挂起等用户决策）。
        // E1：cmd判定收敛至 text_inbound.isTextCmd。
        if (!isTextCmd(msg.cmd.name)) return;
        // E1：msgId 解析收敛至 text_inbound.parseMsgId。
        final msgId = parseMsgId(msg.payload);
        if (isNullId(msgId)) return; // E1：空ID判定委托
        final mid = msgId!;
        // P0-7：对端身份键（deviceId 优先，旧端回退 IP）
        final peerKey = _deviceKeyOf(msg.senderIp, msg.payload);
        // E1：迁移门控抽至 text_inbound.shouldMigrateLegacyCache。
        if (shouldMigrateLegacyCache(peerKey: peerKey, senderIp: msg.senderIp)) {
          _cacheService.migrateLegacyCache(peerKey, msg.senderIp);
        }
        final blocked = await _checkIpBlocked(msg.senderIp, deviceId: peerKey);
        _msgService.sendMsgAck(
          targetIp: msg.senderIp,
          msgId: mid,
          blocked: blocked,
        );
        if (blocked) {
          debugPrint(blockedAckLog(msg.senderIp)); // E1：拉黑ACK日志委托
        }

        // P1-3：内存去重窗口，重试包只回 ACK、不再读缓存
        if (_recvDedup.isDuplicate(mid)) {
          debugPrint(dedupHitLog(mid)); // E1：去重命中日志委托
          return;
        }

        // 全局缓存文字消息 — 无论 ChatPage 是否打开
        // S5：cipher 优先解密；解密失败保留密文占位，不入库乱码。
        // E1：内容回退/去重抽至 text_inbound。
        final decrypted = UdpMessageService.decryptIncomingText(msg.payload);
        final content = resolveInboundTextContent(
          decrypted: decrypted,
          payload: msg.payload,
        );
        final cachedMsgs = await _cacheService.loadMessages(peerKey);
        final isDup = isInboundTextDuplicate(
          cachedIds: [for (final m in cachedMsgs) m.id],
          msgId: mid,
        );
        if (!isDup) {
          // E1：构造抽至 message_factory.buildIncomingText。
          final newMsg = buildIncomingText(
            // E1：ID 抽至 text_inbound.inboundTextMessageId。
            id: inboundTextMessageId(msgId: mid, nowMs: 0),
            senderId: msg.senderIp,
            content: content,
            now: now() /* E1: clock->app_clock.now */,
          );
          await _cacheService.appendMessage(peerKey, newMsg);
          debugPrint(textCachedLog(content, peerKey)); // E1：文字缓存日志委托
        }
        // 更新设备列表的 lastMsg
        if (mounted) {
          setState(() {
            final idx = findFirstIndexById(_allDevices, (d) => d.id, peerKey);
            if (hasFoundIndex(idx)) /* E1：命中委托 */ {
              _allDevices[idx].lastMsg = content;
              _scheduleSaveDeviceList();
            }
          });
        }
      });

      // 注册设备状态变更回调（心跳超时）
      _msgService.setDeviceStatusCallback((deviceId, status) {
        // E1：离线判定收敛至 text_inbound.isOfflineStatus。
        if (isOfflineStatus(status.name)) {
          _onDeviceOffline(deviceId);
        }
      });

      // E1：v4/v6 收包监听已随 socket 生命周期移至 lan_discovery_service。

      _startAdvertising();
      // N4：发现启动后开启看门狗巡检。
      _startWatchdog();
      // N1：mDNS 兜底发现巡检（广播被吞时设备不丢）。
      _startMdnsScan();
      // U2：桌面启动参数（"发送到/打开方式"）待发送路径，发现就绪后触发一次。
      // E1：延迟抽至 transfer_limits.kLaunchSendDelaySec。
      unawaited(
        _maybeConsumeLaunchSend(
          initialDelay: const Duration(seconds: kLaunchSendDelaySec),
        ),
      );
    } catch (e) {
      debugPrint(lanInitFailLog(e)); // E1：初始化失败日志委托
    }
  }

  /// U2：消费桌面启动参数（仅一次）：等待首批在线设备出现（最多 ~15s），
  /// 有在线设备即按路径（文件/目录）走选设备发送；无在线设备则 toast 保留路径提示。
  Future<void> _maybeConsumeLaunchSend({
    Duration initialDelay = Duration.zero,
  }) async {
    // E1：启动消费门控收敛至 send_path_classify.shouldSkipLaunchSend。
    if (shouldSkipLaunchSend(
      consumed: _launchSendConsumed,
      empty: widget.initialSendPaths.isEmpty,
    )) {
      return;
    }
    if (initialDelay > Duration.zero) await Future.delayed(initialDelay);
    _launchSendConsumed = true;
    // 路径仍存在才发送（启动到发现就绪期间文件可能被删）。
    // E1：归类抽至 send_path_classify.classifySendPaths（纯函数可单测）。
    // E1：kind 抽至 device_merge.dirKindForEntity。
    final kinds = <String>[];
    for (final p in widget.initialSendPaths) {
      try {
        final type = FileSystemEntity.typeSync(p, followLinks: false);
        kinds.add(dirKindForEntity(
            isDirectory: type == FileSystemEntityType.directory));
      } catch (_) {
        kinds.add('missing');
      }
    }
    final classified = classifySendPaths(
      paths: widget.initialSendPaths,
      kinds: kinds,
      exists: (p) {
        try {
          final t = FileSystemEntity.typeSync(p, followLinks: false);
          return isSendableEntityType(t); // E1：可发送类型判定委托
        } catch (_) {
          return false;
        }
      },
    );
    final paths = classified.files;
    final folderPath = classified.folderPath;
    if (!hasSendContent(classified)) return;
    // 等首批在线设备（发现刚启动可能尚未收到心跳）。
    // E1：轮询上限抽至 device_tile_meta.shouldKeepWaitingOnline，周期抽至 kLaunchSendPollSec。
    for (var i = 0; shouldKeepWaitingOnline(tried: i); i++) {
      if (!mounted) return;
      if (_onlineDeviceIds.isNotEmpty) break;
      await Future.delayed(const Duration(seconds: kLaunchSendPollSec));
    }
    if (!mounted) return;
    if (_onlineDeviceIds.isEmpty) {
      showCenterToast(context, noOnlineDeviceLongText());
      return;
    }
    final device = await _pickTargetDevice();
    if (device == null || !mounted) return;
    await _openChatWith(
      device,
      // E1：空列表转 null 收敛至 send_path_classify.nullablePathsOrNull。
      pendingFilePaths: nullablePathsOrNull(paths),
      pendingFolderPath: folderPath,
    );
  }

  // ========== P0-7：身份键解析（deviceId 优先，IP 回退） ==========

  /// 由入站消息解析对端身份键：payload 带 deviceId/tlsFp 用之；
  /// 否则按当前 IP 在设备列表反查；都找不到则回退 IP（legacy，E1 纯函数在 device_key_resolver）
  String _deviceKeyOf(String ip, [Map<String, dynamic>? payload]) {
    final did = dkr.deviceIdFromPayload(payload);
    if (did.isNotEmpty) return did;
    // E1/新库 collection：firstWhereOrNull 替代 where+firstOrNull。
    final dev = _allDevices.firstWhereOrNull(
      // E1：IP匹配委托
      (d) => matchesIp(id: d.id, curIp: d.currentIp, ip: ip),
    );
    if (dev != null) return dev.id;
    debugPrint(legacyFallbackLog(ip)); // E1：legacy回退日志委托
    return ip;
  }

  /// 发送前把身份键解析为当前路由 IP；查不到时原样返回（legacy：键即 IP）
  String _resolveIp(String deviceKey) {
    // E1：设备键匹配委托
    final dev = _allDevices.firstWhereOrNull((d) => matchesDeviceKey(d.id, deviceKey));
    return dkr.resolveDeviceIp(deviceKey: deviceKey, currentIp: dev?.currentIp);
  }

  /// P0-7：legacy（IP 键）设备升级为 deviceId 键，并迁移按键存储的配置与缓存
  // P0-7：legacy（IP 键）设备升级为 deviceId 键（E1：编排抽至 peer_presence，
  // 配置/缓存迁移经 onLegacyUpgraded 回调）。
  void _upgradeLegacyDevice(DeviceInfo d, String deviceId) {
    final oldKey = d.id;
    if (_presence.upgradeLegacy(d, deviceId)) {
      debugPrint(legacyUpgradeLog(oldKey, deviceId)); // E1：legacy升级日志委托
    }
  }

  // 设备离线处理（E1：集合变更抽至 peer_presence，在线集合变化自动落盘）。
  void _onDeviceOffline(String deviceId) {
    if (!mounted) return;
    setState(() {
      _presence.markOffline(deviceId);
      final idx = findFirstIndexById(_allDevices, (d) => d.id, deviceId);
      if (hasFoundIndex(idx)) /* E1：命中委托 */ {
        _allDevices[idx].onlineStatus = DeviceOnlineStatus.offline;
        _allDevices[idx].lastMsg = offlineText();
      }
    });
    _scheduleSaveDeviceList();
  }

  /// 执行一次广播（供心跳定时器和快速发现复用）
  /// U4：隐身模式开启时跳过主动广播，仅保留单播回包（_sendDirectReply）。
  /// E1：socket/广播目标抽至 lan_discovery_service。
  void _doBroadcast() {
    // E1：未知判定抽至 chat_defaults.isUnknownIp。
    if (!_discovery.isReady || isUnknownIp(_localIP)) return;
    // N5：paired 档仅对已配对设备单播心跳；stealth 档仅保留单播回包。
    // E1：门控抽至 announce_payload（纯函数可单测）。
    if (shouldSkipBroadcast(visibility: _visibility, stealthMode: _stealthMode)) {
      debugPrint(stealthSkipLog()); // E1：隐身跳过日志委托
      return;
    }
    // E1：档位判定抽至 announce_payload.isPairedOnlyVisibility。
    if (isPairedOnlyVisibility(_visibility)) {
      // E1：掷骰抽至 announce_payload.rollPairedDice。
      if (!allowPairedBroadcast(
        pairedCount: _handshake.paired.length,
        roll0to5: rollPairedDice(),
      )) {
        debugPrint(pairedOnlyIdleLog()); // E1：仅配对空闲日志委托
        return;
      }
      debugPrint(pairedOnlyShardLog()); // E1：仅配对分片日志委托
    }

    // E1：载荷组装抽至 announce_payload.buildAnnouncePayload。
    // E1：类型标签抽至 platform_info.deviceTypeLabel。
    final myInfo = buildAnnouncePayload(
      localIp: _localIP,
      deviceName: _myDeviceName,
      deviceType: deviceTypeLabel(isMobile: PlatformMobileExtension.isMobile),
      cmd: "iamalive",
      deviceId: TlsIdentityService.instance.deviceId,
      udpPort: _discovery.udpPort,
      // v2：tcpPort 对齐 v2 HTTPS 服务端口（两条发现路径端口一致，
      // 避免双端口竞态互相覆盖）
      tcpPort: _lsServer.boundPort,
    );

    // 广播目标（255.255.255.255 / 224.0.0.1 / 各子网广播 / ff02::1）在服务内。
    // 端口集合 = 默认端口探测范围 ∪ 本端端口（announceTargetPorts）：
    // 任一端 UDP 绑定回退后仍能互相命中（原只发本端端口会单通）。
    _discovery.broadcast(
      utf8.encode(jsonEncode(myInfo)),
      announceTargetPorts(UdpMessageService.defaultMsgPort, _discovery.udpPort),
      _subnetBroadcastAddresses,
    );
  }

  /// 定时发送广播：立即发一条，启动阶段快速多发几条，之后恢复 3s 周期
  /// E1：周期抽至 transfer_limits.kBroadcastSec。
  void _startAdvertising() {
    _broadcastTimer?.cancel();

    // 立即发送第一条广播，不等 timer 周期
    _doBroadcast();

    // 启动阶段快速多发：200ms / 600ms 再发两条，加速首次发现
    // E1：抽至 transfer_limits.kBroadcastFastMs1/kBroadcastFastMs2。
    Future.delayed(const Duration(milliseconds: kBroadcastFastMs1), _doBroadcast);
    Future.delayed(const Duration(milliseconds: kBroadcastFastMs2), _doBroadcast);

    // 之后以 3 秒为周期持续广播
    _broadcastTimer = Timer.periodic(
      const Duration(seconds: kBroadcastSec),
      (_) => _doBroadcast(),
    );
  }

  // 处理接收逻辑
  // P1-T8：广播 JSON 解析加 try + 长度校验（超 64KB 直接丢弃）。
  void _handleIncomingBroadcast(
    String rawData,
    String senderIP, [
    int? srcPort,
  ]) {
    if (_localIPList.contains(senderIP)) {
      return;
    }
    // E1：超大门控抽至 device_lookup.isOversizeBroadcast。
    if (isOversizeBroadcast(rawData)) {
      debugPrint(oversizeLog(rawData.length, senderIP)); // E1：超大包日志委托
      return;
    }

    try {
      // E1：双重 JSON 解码抽至 device_lookup.decodeBroadcastMap。
      final deviceData = decodeBroadcastMap(rawData);
      if (isNullId(deviceData)) return; // E1：空判定委托
      final dd = deviceData!;
      String cmd = broadcastCmdOf(dd); // E1：广播命令回退委托

      // E1：心跳命令判定抽至 device_lookup.isHeartbeatCmd。
      if (isHeartbeatCmd(cmd)) {
        // 广播中的 id 可能是 0.0.0.0（发送方 IP 检测失败时），
        // E1：回退链（payload.id → 来源 IP → payload.senderIp）抽至
        // device_key_resolver.resolveBroadcastIdentity（可单测）。
        final identity = dkr.resolveBroadcastIdentity(dd, senderIP);
        if (isNullId(identity)) { // E1：空身份判定委托
          // E1：未知发送方日志纯函数委托。
          debugPrint(unknownSenderLog(dd['id'], senderIP, dd['senderIp']));
          return; // 无法确定身份，丢弃
        }
        final id = identity!.ip;
        if (_localIPList.contains(id)) return;

        // E1：名/类型回退抽至 device_lookup.broadcastNameOf/broadcastTypeOf。
        String name = broadcastNameOf(dd);
        String type = broadcastTypeOf(dd);
        // E1：端口归一抽至 device_lookup.normalizeUdpPort/normalizeTcpPort。
        final peerUdpPort = normalizeUdpPort(
          dd,
          srcPort,
          UdpMessageService.defaultMsgPort,
        );
        final peerTcpPort = normalizeTcpPort(
          dd,
          kLsDefaultPort, // v2：回退端口对齐 LocalSend 标准 53317
        );

        // P0-7：身份键优先 deviceId（持久、换 IP 不变）；旧端无 deviceId 回退 IP。
        // `id` 此时已解析为对端实际 IP，仅作路由地址（E1 复用 deviceIdFromPayload）。
        final peerIp = id;
        final deviceKey = identity.deviceKey; // E1：首个断言后已收窄

        // P0-S2：已拉黑指纹设备直接忽略。
        // P1-10（对齐 LocalSend）：发现阶段不再弹配对确认框，设备直接可用；
        // 配对改为设备卡片长按手动发起，未配对传输由文件级同意兜底。
        if (_handshake.blocked.contains(deviceKey)) {
          debugPrint(blockedIgnoreLog(deviceKey)); // E1：拉黑忽略日志委托
          return;
        }

        // P0-7：若已有同 IP 的 legacy（IP 键）设备，升级为 deviceId 键并迁移配置/缓存；
        // 同一 deviceId 换 IP 时更新路由地址 currentIp。
        // E1：合并索引收敛至 findDeviceMergeIndex。
        final devIdx = findDeviceMergeIndex(
          _allDevices,
          (d) => d.id,
          (d) => d.currentIp,
          deviceKey,
          peerIp,
        );
        if (hasFoundIndex(devIdx)) /* E1：命中委托 */ {
          final dev = _allDevices[devIdx];
          if (isLegacyKey(dev.id, deviceKey)) { // E1：旧键判定委托
            _upgradeLegacyDevice(dev, deviceKey);
          }
          dev.currentIp = peerIp;
        }

        // 记录心跳（按身份键）+ 记住对端 UDP 端口（P1-1）
        _msgService.recordHeartbeat(deviceKey);
        _msgService.rememberPeerUdpPort(peerIp, peerUdpPort);

        // 桌面端对手机端进行单播响应
        // E1：抽至 device_lookup.shouldDirectReply/onlineLabelForCmd。
        if (shouldDirectReply(
          cmd: cmd,
          type: type,
          isMobile: PlatformMobileExtension.isMobile,
        )) {
          _sendDirectReply(senderIP);
        }

        // E1：设备条目合并（广播与 N1 mDNS 兜底发现共用）。
        // E1：新建默认文案抽至 device_lookup.newDeviceOnlineText。
        final isNew = _upsertDevice(
          deviceKey: deviceKey,
          peerIp: peerIp,
          name: name,
          type: type,
          udpPort: peerUdpPort,
          tcpPort: peerTcpPort,
          lastMsg: onlineLabelForCmd(cmd),
          newLastMsg: newDeviceOnlineText(),
        );
        if (isNew) {
          debugPrint(mdnsFoundLog(name, deviceKey, peerIp)); // E1：跨端上线日志委托
        }
        // P1-T7：对端上线/在线（心跳到达）时重推离线文字（队列为空时 no-op）。
        _flushOfflineTexts(deviceKey);
      }
    } catch (e) {
      // P1-T8：广播 JSON 解析加 try + 长度校验（超 64KB 直接丢弃）。
      debugPrint(broadcastParseFailLog(e)); // E1：广播解析失败日志委托
    }
  }

  /// E1/N1：设备条目合并（在线置位 + 字段更新 + 防抖落盘）。
  /// [lastMsg] 更新已有设备/新建设备的展示文案，[newLastMsg] 仅新建用。
  /// 数据无变化时静默刷新 lastSeen（在线设备 UI 无变化，少一次重建与落盘）。
  /// 返回是否新建了设备条目。
  bool _upsertDevice({
    required String deviceKey,
    required String peerIp,
    required String name,
    required String type,
    required int udpPort,
    required int tcpPort,
    required String lastMsg,
    String? newLastMsg,
  }) {
    final existingIndex = findFirstIndexById(_allDevices, (d) => d.id, deviceKey);
    final isNew = isMissingIndex(existingIndex); // E1：未命中委托
    if (!isNew) {
      final dev = _allDevices[existingIndex];
      // E1：无变化判定抽至 device_merge.isDeviceUnchanged。
      final unchanged = isDeviceUnchanged(
        name: name,
        type: type,
        onlineStatus: 'online',
        currentIp: peerIp,
        udpPort: udpPort,
        tcpPort: tcpPort,
        lastMsg: lastMsg,
        curName: dev.name,
        curType: dev.type,
        curOnlineStatus: dev.onlineStatus.name,
        curIp: dev.currentIp,
        curUdpPort: dev.udpPort,
        curTcpPort: dev.tcpPort,
        curLastMsg: dev.lastMsg,
      );
      if (unchanged) {
        dev.lastSeen = now() /* E1: clock->app_clock.now */;
        return false;
      }
    }
    setState(() {
      // E1：在线集合变更抽至 peer_presence（变化自动落盘）。
      _presence.markOnline(deviceKey);
      if (isNew) {
        _allDevices.add(
          DeviceInfo(
            id: deviceKey,
            currentIp: peerIp,
            name: name,
            type: type,
            lastMsg: resolveLastMsg(newLastMsg, lastMsg), // E1：新建文案回退委托
            onlineStatus: DeviceOnlineStatus.online,
            udpPort: udpPort,
            tcpPort: tcpPort,
          ),
        );
      } else {
        final dev = _allDevices[existingIndex];
        dev.name = name;
        dev.type = type;
        dev.onlineStatus = DeviceOnlineStatus.online;
        dev.lastSeen = now() /* E1: clock->app_clock.now */;
        dev.currentIp = peerIp;
        dev.udpPort = udpPort;
        dev.tcpPort = tcpPort;
        dev.lastMsg = lastMsg;
      }
    });
    _scheduleSaveDeviceList();
    return isNew;
  }

  // ========== U2：从其他 App 分享进来（Android SEND intent；iOS 扩展待加） ==========

  /// 读取初始分享 + 监听分享流（运行中收到）。
  Future<void> _handleInboundShares() async {
    final intent = ReceiveSharingIntent.instance;
    try {
      final initial = await intent.getInitialMedia();
      if (initial.isNotEmpty && mounted) {
        await _handleSharedMedia(initial);
      }
      await intent.reset();
    } catch (e) {
      debugPrint(shareIntentFailLog(e)); // E1：分享意图失败日志委托
    }
    _shareSub = intent.getMediaStream().listen(
      (media) {
        if (media.isEmpty) return;
        unawaited(_handleSharedMedia(media));
      },
      onError: (Object e) {
        debugPrint(shareStreamFailLog(e)); // E1：分享流失败日志委托
      },
    );
  }

  /// 文字分享 → 选设备 → 进 ChatPage 自动发送；文件/图片/视频分享同路。
  /// E1：单项归类抽至 share_classify（纯函数可单测），存在性检查留此处。
  Future<void> _handleSharedMedia(List<SharedMediaFile> media) async {
    for (final item in media) {
      if (!mounted) return;
      final r = classifyShareItem(type: item.type.name, path: item.path);
      // E1：跳过/文本/路径取值收敛至 share_classify。
      if (isSkipShare(r)) continue;
      final text = shareTextOf(r);
      final path = sharePathOf(r);
      final pth0 = path;
      if (isNotNull(pth0)) { // E1：非空判定委托
        try {
          if (!await File(pth0!).exists()) continue;
        } catch (_) {
          continue;
        }
      }
      final device = await _pickTargetDevice();
      if (isNullId(device)) return; // E1：空判定委托 // 用户取消，不再处理后续分享项
      final dv2 = device;
      await _openChatWith(
        dv2!, // E1：空判定后断言
        pendingText: text,
        // E1：单路径转可空列表收敛至 share_classify.singlePathListOrNull。
        pendingFilePaths: singlePathListOrNull(path),
      );
    }
  }

  /// U2：分享目标设备选择（仅在线设备；无在线设备 toast）。
  /// E1：在线过滤+按名排序复用 device_sort（纯函数可单测）。
  Future<DeviceInfo?> _pickTargetDevice() async {
    if (!mounted) return null;
    final onlineIds = _onlineDeviceIds;
    final online = sortDevicesOnlineFirst(
      // E1：在线过滤收敛至 filterOnlineDevices。
      devices: filterOnlineDevices(_allDevices, onlineIds, (d) => d.id),
      idOf: (d) => d.id,
      nameOf: (d) => d.name,
      onlineIds: onlineIds,
    );
    if (online.isEmpty) {
      showCenterToast(context, noOnlineDeviceShortText());
      return null;
    }
    return showDialog<DeviceInfo>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(sendToTitle()),
        content: SizedBox(
          width: 280,
          child: ListView.builder(
            shrinkWrap: true,
            // E1：设备计数委托。
            itemCount: deviceCount(online),
            itemBuilder: (ctx, i) {
              // E1：视觉三件套抽至 device_tile_meta.resolveDeviceTileVisual。
              final v = resolveDeviceTileVisual(
                isMobile: isMobileType(online[i].type),
                isOnline: true,
              );
              return ListTile(
                leading: Icon(
                  // E1：图标手机判定复用 tileIconIsMobile（import 已有）
                  tileIconIsMobile(iconMobile: v.iconMobile)
                      ? Icons.phone_android
                      : Icons.computer,
                  // E1：前景回退收敛至 device_tile_meta.resolveFgColor。
                  color: Color(resolveFgColor(fg: v.fg)),
                ),
                title: Text(online[i].name),
                subtitle: Text(
                  online[i].id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.pop(ctx, online[i]),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(cancelText()),
          ),
        ],
      ),
    );
  }

  /// E1/U2：打开聊天页（设备条目点击与分享/拖拽进入共用），
  /// 返回后同步拉黑列表与自动接收配置；[pendingText]/[pendingFilePaths]/
  /// [pendingFolderPath] 为分享或拖拽进入的初始待发送内容（ChatPage 加载完毕后自动发送）。
  Future<void> _openChatWith(
    DeviceInfo device, {
    String? pendingText,
    List<String>? pendingFilePaths,
    String? pendingFolderPath,
  }) async {
    // U2：setState 使拖拽目标在聊天页打开期间禁用
    // （desktop_drop 已知问题：被遮挡时仍收拖拽事件）。
    setState(() {
      _openChatDeviceIPs.add(device.id);
    });
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatPage(
          id: device.id,
          title: device.name,
          peerIp: device.currentIp,
          peerTcpPort: device.tcpPort,
          msgService: _msgService,
          myDeviceName: _myDeviceName,
          lsServer: _lsServer,
          initialAutoReceive: _getAutoReceive(device.id),
          onAutoReceiveChanged: (v) => _setAutoReceive(device.id, v),
          onManualAcceptFile: (ip, name, tid, {sessionId}) =>
              _onUserManualAcceptFile(ip, name, tid, sessionId: sessionId),
          onManualRejectFile: (ip, name, tid, {sessionId}) =>
              _onUserManualRejectFile(ip, name, tid, sessionId: sessionId),
          onTextSendFailed: (msgId, text) =>
              _enqueueOfflineText(device.id, msgId, text),
          initialPendingText: pendingText,
          // E1：待发路径回退收敛至 send_path_classify.resolvePendingPaths。
          initialPendingFilePaths: resolvePendingPaths(pendingFilePaths),
          initialPendingFolderPath: pendingFolderPath,
        ),
      ),
    );
    setState(() {
      _openChatDeviceIPs.remove(device.id);
    });
    // 从 ChatPage 返回后重新加载拉黑列表和自动接收配置
    await _handshake.reloadBlocked();
    await _loadAutoReceiveConfig();
  }

  /// U2：拖拽文件/文件夹到设备列表 → 选设备 → 进 ChatPage 发送
  /// （多文件走批量会话，文件夹打包 zip 由 ChatPage 处理）。
  /// E1：归类抽至 send_path_classify（纯函数可单测），IO 存在检查保留在外层。
  Future<void> _handleDroppedFiles(List<DropItem> files) async {
    // E1：拖拽丢弃门控委托（IO 存在检查留宿主）。
    if (abortDrop(empty: files.isEmpty, mounted: mounted)) return;
    final classified = classifySendPaths(
      paths: files.map((f) => f.path).toList(),
      // E1：kind 收敛至 dropKindForItem。
      kinds: files.map((f) => dropKindForItem(f is DropItemDirectory)).toList(),
    );
    // 拖入文件夹只发第一个由归类保证；文件需二次确认仍存在（拖拽期间可能删除）。
    final paths = <String>[];
    for (final p in classified.files) {
      try {
        if (await File(p).exists()) paths.add(p);
      } catch (_) {}
    }
    final folderPath = classified.folderPath;
    if (!hasSendContent((files: paths, folderPath: folderPath))) return;
    final device = await _pickTargetDevice();
    final dv = device;
    if (isNullId(dv)) return; // E1：空判定委托
    await _openChatWith(
      dv!,
      // E1：空列表转 null 收敛至 send_path_classify.nullablePathsOrNull。
      pendingFilePaths: nullablePathsOrNull(paths),
      pendingFolderPath: folderPath,
    );
  }

  // 精准单播应答函数
  void _sendDirectReply(String targetIP) {
    // E1：回包载荷抽至 announce_payload（与广播共用组装）。
    // E1：类型标签抽至 platform_info.deviceTypeLabel。
    final replyInfo = buildAnnouncePayload(
      localIp: _localIP,
      deviceName: _myDeviceName,
      deviceType: deviceTypeLabel(isMobile: PlatformMobileExtension.isMobile),
      cmd: "i_see_you",
      deviceId: TlsIdentityService.instance.deviceId,
      udpPort: _discovery.udpPort,
      // v2：tcpPort 对齐 v2 HTTPS 服务端口（与广播路径一致）
      tcpPort: _lsServer.boundPort,
    );

    final destPort = resolveReplyPort(
      // E1/新库 collection：firstWhereOrNull 替代 where+firstOrNull。
      knownUdpPort: _allDevices
          .firstWhereOrNull((d) => d.currentIp == targetIP)
          ?.udpPort,
      defaultPort: UdpMessageService.defaultMsgPort,
    );
    // N2：v6 目标走 v6 socket（无 v6 socket 时回退 v4，旧行为不变），
    // E1：socket 选栈抽至 lan_discovery_service.sendTo。
    final ok = _discovery.sendTo(utf8.encode(jsonEncode(replyInfo)), targetIP, destPort);
    if (ok) {
      debugPrint(unicastHandshakeLog(targetIP)); // E1：单播握手日志委托
    } else {
      // P1-N6：握手失败多半是目标 UDP 端口不对，提示检查端口
      if (mounted) {
        showCenterToast(context, handshakeFailText(destPort));
      }
    }
  }

  /// P1-N1：手动添加设备（E1：输入框 UI 移至 settings_tab，
  /// IP:端口 解析抽至 lan_utils.parseEndpoint 可单测）。
  Future<void> _onAddDeviceRequest(String result) async {
    final parsed = LanUtils.parseEndpoint(result);
    final ps = parsed;
    if (isNullId(ps)) { // E1：空判定委托
      if (mounted) showCenterToast(context, badIpText());
      return;
    }
    final ip = ps!.ip;
    final port = ps.port; // E1：首个断言后已提升
    _msgService.rememberPeerUdpPort(ip, port);
    final ok = await _msgService.pingDevice(ip);
    _msgService.recordHeartbeat(ip);
    if (!mounted) return;
    setState(() {
      _presence.markOnline(ip);
      final idx = findFirstIndexById(_allDevices, (d) => d.id, ip);
      if (hasFoundIndex(idx)) /* E1：命中委托 */ {
        _allDevices[idx].currentIp = ip;
        _allDevices[idx].udpPort = port;
        // E1：手动在线判定收敛至 text_inbound.isManualOnline（枚举构造留宿主）。
        _allDevices[idx].onlineStatus = isManualOnline(ok)
            ? DeviceOnlineStatus.online
            : DeviceOnlineStatus.unknown;
        _allDevices[idx].lastSeen = now() /* E1: clock->app_clock.now */;
        // E1：文案抽至 arrival_texts.manualLastMsg。
        _allDevices[idx].lastMsg = manualLastMsg(ok);
      } else {
        _allDevices.add(
          DeviceInfo(
            id: ip,
            currentIp: ip,
            // E1：文案抽至 arrival_texts.manualName/manualLastMsg。
            name: manualName(ok),
            type: 'desktop',
            lastMsg: manualLastMsg(ok),
            // E1：手动在线判定收敛至 text_inbound.isManualOnline（枚举构造留宿主）。
            onlineStatus: isManualOnline(ok)
                ? DeviceOnlineStatus.online
                : DeviceOnlineStatus.unknown,
            udpPort: port,
          ),
        );
      }
    });
    _scheduleSaveDeviceList();
    if (!ok && mounted) {
      // E1：文案抽至 device_lookup.deviceNoResponseText。
      showCenterToast(context, deviceNoResponseText(port));
    }
  }

  void _refreshDevices() {
    // 不清除 _allDevices，保留缓存设备（仅清除在线状态，重新扫描会更新）
    setState(() {
      // E1：在线集合清空抽至 peer_presence。
      _presence.onlineIds.clear();
      // 将所有设备标记为 unknown，等扫描到后再更新为 online
      for (final d in _allDevices) {
        d.onlineStatus = DeviceOnlineStatus.unknown;
        d.lastMsg = scanningDeviceText();
      }
    });
    _initLanDiscovery();
    showCenterToast(context, rescanningText());
  }

  // ================= 文件存储路径设置 =================

  /// 加载存储路径与首选端口（缺省 8888/8899）。
  Future<void> _loadStoragePath() async {
    final config = await StorageConfig.load();
    final path = config.storagePath;
    final sp = path;
    if (isNotNull(sp)) { // E1：非空判定委托
      _storagePathLabel = sp!;
      _lsServer.setSaveDirectory(sp); // v2：保存目录注入 LsServer
      debugPrint(storageLoadedLog(path)); // E1：存储路径日志委托
    }
    // E1：配置端口回退委托（有配置用配置，否则沿用当前首选）。
    _preferredUdpPort = resolvePort(config.udpPort, _preferredUdpPort);
    _preferredTcpPort = resolvePort(config.tcpPort, _preferredTcpPort);
  }

  /// P0-S3：加载仅TLS开关（默认 true）
  Future<void> _loadTlsOnly() async {
    final v = await AppConfigStore.getTlsOnly();
    if (mounted) {
      setState(() {
        _tlsOnly = v;
      });
    }
  }

  /// P0-S3：切换仅TLS开关并持久化
  Future<void> _setTlsOnly(bool v) async {
    setState(() {
      _tlsOnly = v;
    });
    await AppConfigStore.setTlsOnly(v);
    debugPrint(tlsOnlyLog(v)); // E1：TLS开关日志委托
  }

  /// S2：加载接收 PIN（空=不启用）
  Future<void> _loadReceivePin() async {
    final v = await AppConfigStore.getReceivePin();
    if (mounted) {
      setState(() {
        _receivePin = v;
      });
    } else {
      _receivePin = v;
    }
  }

  /// N5：加载发现可见性三档（默认 all），同步旧 _stealthMode 兼容位。
  Future<void> _loadVisibility() async {
    final v = await AppConfigStore.getVisibility();
    // E1：隐身判定抽至 device_lookup.stealthForVisibility。
    if (mounted) {
      setState(() {
        _visibility = v;
        _stealthMode = stealthForVisibility(v);
      });
    } else {
      _visibility = v;
      _stealthMode = stealthForVisibility(v);
    }
  }

  /// N5：切换发现可见性三档并持久化（E1：对话框 UI 移至 settings_tab）。
  Future<void> _onVisibilityChanged(String v) async {
    setState(() {
      _visibility = v;
      _stealthMode = stealthForVisibility(v);
    });
    await AppConfigStore.setVisibility(v);
    debugPrint(visibilityLog(v)); // E1：可见性日志委托
    if (mounted) {
      // E1：文案抽至 device_lookup.visibilityToast。
      showCenterToast(context, visibilityToast(v));
    }
  }

  /// U4：加载隐身模式开关（默认 false）
  Future<void> _loadStealthMode() async {
    final v = await AppConfigStore.getStealthMode();
    if (mounted) {
      setState(() {
        _stealthMode = v;
      });
    }
  }

  /// U4：切换隐身模式开关并持久化（开启后跳过主动广播，仅单播回包）
  Future<void> _setStealthMode(bool v) async {
    setState(() {
      _stealthMode = v;
    });
    await AppConfigStore.setStealthMode(v);
    debugPrint(stealthModeLog(v)); // E1：隐身模式日志委托
  }

  /// S2：接收 PIN 保存（校验格式 + 持久化；E1：对话框 UI 移至 settings_tab）。
  Future<void> _onReceivePinSave(String pin) async {
    final ok = await AppConfigStore.setReceivePin(pin);
    if (!mounted) return;
    if (!ok) {
      showCenterToast(context, pinFormatErrorText());
      return;
    }
    setState(() {
      _receivePin = pin;
    });
    // E1：文案抽至 pin_texts.pinSavedText。
    showCenterToast(context, pinSavedText(pin));
  }

  /// P1-T7：发送失败入队离线队列（deviceKey -> 待重推文字）。
  void _enqueueOfflineText(String deviceKey, String msgId, String text) {
    _pendingOfflineTexts.enqueue(deviceKey, msgId, text);
    debugPrint(offlineFlushLog(deviceKey, msgId, _pendingOfflineTexts.lengthOf(deviceKey))); // E1：离线入队日志委托
  }

  /// P1-T7：对端上线时重推离线文字（best-effort，失败保留队列）。
  /// S5：deviceKey 为 64 位指纹时同样加密重推；旧端走明文兼容。
  Future<void> _flushOfflineTexts(String deviceKey) async {
    final list = _pendingOfflineTexts.items(deviceKey);
    final ls = list;
    if (isNullId(ls) || ls!.isEmpty) return; // E1：空判定委托
    final lsn = ls; // E1：条件断言后已提升
    final targetIp = _resolveIp(deviceKey);
    // E1：指纹回退抽至 pin_texts.peerFingerprintOrNull。
    final peerFp = peerFingerprintOrNull(
      deviceKey,
      LanUtils.isFingerprintKey(deviceKey),
    );
    final pending = List.of(lsn);
    for (final item in pending) {
      try {
        final ok = await _msgService.sendTextMessage(
          targetIp: targetIp,
          content: item.text,
          senderName: _myDeviceName,
          msgId: item.msgId,
          peerFingerprint: peerFp,
        );
        if (ok) {
          _pendingOfflineTexts.removeItem(deviceKey, item);
          debugPrint(offlineResendLog(deviceKey, item.msgId)); // E1：离线重推日志委托
        }
      } catch (e) {
        debugPrint(offlineRetainLog(e)); // E1：离线保留日志委托
        break;
      }
    }
  }

  /// 持久化存储路径配置
  Future<void> _saveStorageConfig(String path) => StorageConfig.save(
    path: path,
    udpPort: _preferredUdpPort,
    tcpPort: _preferredTcpPort,
  );

  /// 存储路径应用（E1：选择器 UI 移至 settings_tab）。
  Future<void> _onStoragePathSelected(String selectedPath) async {
    try {
      final dir = Directory(selectedPath);
      if (!await dir.exists()) {
        if (mounted) showCenterToast(context, storageMissingText());
        return;
      }
      setState(() {
        _storagePathLabel = selectedPath;
      });
      _lsServer.setSaveDirectory(selectedPath); // v2：保存目录注入 LsServer
      await _saveStorageConfig(selectedPath);
      if (mounted) {
        showCenterToast(context, storageUpdatedText());
      }
    } catch (e) {
      debugPrint(storageApplyFailLog(e)); // E1：存储应用失败日志委托
      if (mounted) showCenterToast(context, storageFailText());
    }
  }

  /// 手动修复 Windows 防火墙（设置页入口）。
  /// P1-1：按实际绑定的 TCP/UDP 端口添加入站规则。
  /// v2：不重启服务（LsServer 端口绑定与旧实现无关，规则添加后即生效）。
  Future<void> _fixFirewall() async {
    try {
      final success = await _fixWindowsFirewall(
        port: _lsServer.boundPort,
        udpPort: _discovery.udpPort,
      );
      if (!mounted) return;

      if (success) {
        // E1：文案抽至 device_lookup.firewallAddedText。
        showCenterToast(
          context,
          firewallAddedText(_lsServer.boundPort, _discovery.udpPort),
        );
      } else {
        showCenterToast(context, firewallAdminText());
      }
    } catch (e) {
      debugPrint(firewallFailLog(e)); // E1：防火墙失败日志委托
      if (mounted) {
        showCenterToast(context, firewallErrorText());
      }
    }
  }

  /// P1-1：端口落地（E1：输入框 UI 移至 settings_tab，范围校验在 UI 层）。
  /// [udp]=true 重启发现（重绑 UDP + v6 + mDNS），false 重启 TCP 服务器并通告。
  Future<void> _onPortChanged(bool udp, int port) async {
    if (udp) {
      _preferredUdpPort = port;
    } else {
      _preferredTcpPort = port;
    }
    await _saveStorageConfig(
      // E1：存储落盘路径回退委托
      resolveStorageSavePath(_storagePathLabel),
    );
    if (udp) {
      await _initLanDiscovery();
    } else {
      // v2：重启 LsServer（stop 后重新绑定首选端口）
      _lsServer.stop();
      try {
        await _lsServer.start(preferredPort: _preferredTcpPort);
        // N1：TCP 端口变更后按新端口重发 mDNS 发布。
        await _mdns.unpublish();
        unawaited(
          _mdns.publishAnnounce(
            name: _myDeviceName,
            port: _lsServer.boundPort,
            deviceId: TlsIdentityService.instance.deviceId,
            udpPort: _discovery.udpPort,
          ),
        );
        // E1：TCP回退判定委托。
        if (isTcpFallback(_lsServer.boundPort, _preferredTcpPort) && mounted) {
          // E1：文案抽至 device_lookup.tcpFallbackText/tcpUpdatedText。
          showCenterToast(
            context,
            tcpFallbackText(_preferredTcpPort, _lsServer.boundPort),
          );
        } else if (mounted) {
          showCenterToast(context, tcpUpdatedText(_lsServer.boundPort));
        }
      } catch (e) {
        if (mounted) showCenterToast(context, tcpBindFailText(e));
      }
    }
    if (mounted) setState(() {});
  }

  /// P0-S6：重置本机身份（E1：确认框 UI 移至 settings_tab）。
  /// 删除旧证书并生成新证书，需对端重新配对（指纹变更，旧 TOFU 信任失效）。
  Future<void> _onResetIdentityConfirm() async {
    try {
      await TlsIdentityService.instance.resetIdentity();
      await _logSecurityEvent('reset_identity');
      if (!mounted) return;
      showCenterToast(context, identityResetText());
    } catch (e) {
      debugPrint(identityResetFailLog(e)); // E1：身份重置失败日志委托
      if (mounted) showCenterToast(context, identityResetFailText(e));
    }
  }

  /// P0-S6：安全事件记账（security_config.json），失败只打日志。
  /// E1：解析/追加抽至 security_event（纯函数可单测），IO 留此处。
  Future<void> _logSecurityEvent(String type) async {
    try {
      final raw = await AppConfigStore.read(AppConfigStore.securityFile);
      final config = parseSecurityConfig(raw);
      final next = appendSecurityEvent(
        config: config,
        type: type,
        timeIso: now().toIso8601String() /* E1: clock->app_clock.now */,
        fingerprint: TlsIdentityService.instance.fingerprint,
      );
      await AppConfigStore.writeAtomic(
        AppConfigStore.securityFile,
        jsonEncode(next),
      );
    } catch (e) {
      debugPrint(securityEventFailLog(e)); // E1：安全事件失败日志委托
    }
  }

  // 删除所有设备及聊天记录（E1：确认框 UI 移至 settings_tab）
  Future<void> _onDeleteAllDevicesConfirm() async {
    try {
      await _cacheService.clearAllMessages();
      setState(() {
        _allDevices.clear();
      });
      if (mounted) {
        showCenterToast(context, deleteAllDoneText());
      }
    } catch (e) {
      if (mounted) {
        showCenterToast(context, deleteFailText(e));
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
        // E1：setState tab 切换留宿主（仅赋值+重建，无纯判定可抽）。
        onTap: (index) => setState(() => _currentIndex = index),
        type: BottomNavigationBarType.fixed,
        backgroundColor: const Color(0xFFF7F7F7),
        selectedItemColor: const Color(0xFF07C160),
        unselectedItemColor: Colors.black87,
        selectedFontSize: 10.5,
        unselectedFontSize: 10.5,
        items: [
          BottomNavigationBarItem(
            // E1：图标判定抽至 device_tile_meta.useSolidTabIcon。
            icon: Icon(
              useSolidTabIcon(currentIndex: _currentIndex, tabIndex: 0)
                  ? Icons.chat_bubble
                  : Icons.chat_bubble_outline,
            ),
            label: msgTabLabel(),
          ),
          BottomNavigationBarItem(
            icon: Icon(
              useSolidTabIcon(currentIndex: _currentIndex, tabIndex: 1)
                  ? Icons.settings
                  : Icons.settings_outlined,
            ),
            label: settingTabLabel(),
          ),
        ],
      ),
    );
  }

  // ================= 消息 Tab 页（美化后的设备列表） =================
  Widget _buildMessageTab() {
    // E1：排序抽至 device_sort（在线优先 + 名字，可单测）。
    final sortedDevices = sortDevicesOnlineFirst(
      devices: _allDevices,
      idOf: (d) => d.id,
      nameOf: (d) => d.name,
      onlineIds: _onlineDeviceIds,
    );

    return Scaffold(
      backgroundColor: const Color(0xFFEDF0F3),
      appBar: AppBar(
        title: Text(lanTitleText()),
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
      body: _isLoadingCache
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CupertinoActivityIndicator(radius: 14),
                  const SizedBox(height: 16),
                  Text(
                    loadingCacheText(),
                    style: TextStyle(color: Colors.grey[600], fontSize: 14),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    localIpText(_localIP),
                    style: TextStyle(color: Colors.grey[400], fontSize: 12),
                  ),
                ],
              ),
            )
          : // E1：空设备收敛至 device_tile_meta.hasNoDevices。
          hasNoDevices(isEmpty: sortedDevices.isEmpty)
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // E1：缓存错误展示判定收敛至 device_merge.shouldShowCacheError。
                  if (shouldShowCacheError(_cacheLoadError)) ...[
                    Icon(
                      Icons.error_outline,
                      size: 36,
                      color: Colors.orange[300],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      cacheErrorTitle(),
                      style: TextStyle(color: Colors.grey[600], fontSize: 14),
                    ),
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        // E1：非空断言委托（text_inbound.requireNonNullHint）。
                        requireNonNullHint(_cacheLoadError),
                        style: TextStyle(color: Colors.grey[400], fontSize: 11),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _cacheLoadError = null;
                          _isLoadingCache = true;
                        });
                        _loadCachedDevices();
                      },
                      child: Text(retryLoadText()),
                    ),
                  ] else ...[
                    const CupertinoActivityIndicator(radius: 12),
                    const SizedBox(height: 12),
                    Text(
                      searchingLanText(),
                      style: TextStyle(color: Colors.grey[600], fontSize: 14),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      localIpText(_localIP),
                      style: TextStyle(color: Colors.grey[400], fontSize: 12),
                    ),
                  ],
                ],
              ),
            )
          : DropTarget(
              // E1：启用门控抽至 device_tile_meta.dropEnabled。
              enable: dropEnabled(
                isDesktop: _isDesktopPlatform,
                loadingCache: _isLoadingCache,
                // E1：开聊集合收敛至 device_tile_meta.hasOpenChat。
                hasOpenChat: hasOpenChat(_openChatDeviceIPs),
              ),
              onDragEntered: (_) => setState(() => _dragging = true),
              onDragExited: (_) => setState(() => _dragging = false),
              onDragDone: (details) {
                setState(() => _dragging = false);
                unawaited(_handleDroppedFiles(details.files));
              },
              child: Container(
                // E1：拖拽高亮判定委托（装饰挂载留宿主，只抽 bool）。
                decoration: hasDragHighlight(_dragging)
                    ? BoxDecoration(
                        border: Border.all(
                          color: const Color(0xFF07C160),
                          width: 2,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      )
                    : null,
                child: ListView.separated(
                  // E1：设备计数委托。
                  itemCount: deviceCount(sortedDevices),
                  separatorBuilder: (context, index) => Divider(
                    height: 1,
                    // E1：分隔线魔法数字委托。
                    thickness: sepThickness(),
                    indent: sepIndent(),
                    color: Color(0xFFE5E5E5),
                  ),
                  itemBuilder: (context, index) {
                    final device = sortedDevices[index];
                    final isOnline = _onlineDeviceIds.contains(device.id);

                    return _buildDeviceItem(device, isOnline);
                  },
                ),
              ),
            ),
    );
  }

  Widget _buildDeviceItem(DeviceInfo device, bool isOnline) {
    // E1：视觉三件套抽至 device_tile_meta.resolveDeviceTileVisual（纯函数可单测）。
    final v = resolveDeviceTileVisual(
      isMobile: isMobileType(device.type),
      isOnline: isOnline,
    );
    final IconData deviceIcon =
        // E1：图标手机判定收敛至 device_tile_meta.tileIconIsMobile。
        tileIconIsMobile(iconMobile: v.iconMobile)
            ? Icons.phone_android
            : Icons.computer;
    final Color iconBgColor = Color(v.bg);
    // E1：前景色收敛至 device_tile_meta.tileFgColorOrGrey（宿主包 Color）。
    final Color iconColor = Color(tileFgColorOrGrey(v.fg));

    return InkWell(
      onTap: () => _openChatWith(device),
      // P1-10（对齐 LocalSend）：配对入口收敛为长按设备卡片，主动发起。
      onLongPress: () => _promptPairing(device.id, device.name),
      child: Container(
        // E1：抽至 device_tile_meta.tileContainerBg。
        color: Color(tileContainerBg(isOnline: isOnline)),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            // 头像区域 - 带在线状态指示
            Stack(
              children: [
                Container(
                  // E1：头像尺寸委托（原值 48.0）。
                  width: tileAvatarSize(),
                  height: tileAvatarSize(),
                  decoration: BoxDecoration(
                    color: iconBgColor,
                    borderRadius: BorderRadius.circular(12),
                    // E1：描边门控抽至 device_tile_meta.showTileOnlineRing。
                    border: showTileOnlineRing(isOnline: isOnline)
                        ? Border.all(
                            color: const Color(
                              0xFF07C160,
                            ).withValues(alpha: 0.3),
                            width: 1.5,
                          )
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
                      child: const Icon(
                        Icons.check,
                        size: 10,
                        color: Colors.white,
                      ),
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
                          // E1：样式抽至 device_tile_meta.deviceNameStyle。
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight:
                                // E1：字重在线判定收敛至 device_tile_meta.isOnlineNameWeight。
                                isOnlineNameWeight(
                                        weight: deviceNameStyle(
                                                isOnline: isOnline)
                                            .weight)
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                            color: Color(
                              deviceNameStyle(isOnline: isOnline).color,
                            ),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isOnline)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(
                              0xFF07C160,
                            ).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            onlineBadgeText(),
                            style: TextStyle(
                              fontSize: 10,
                              color: Color(0xFF07C160),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        )
                      else
                        Text(
                          formatLastSeen(device.lastSeen),
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey[400],
                          ),
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
                        // E1：副文本色抽至 device_tile_meta.tileSubtitleColor。
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Color(
                            tileSubtitleColor(isOnline: isOnline),
                          ),
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

  // E1：_formatLastSeen 已移至 Services/time_format.dart。

  // P2-1：广播/私有 IP 工具已移至 LanUtils，旧定义删除。

  // ================= 设置 Tab 页（E1：UI + 对话框群移至 settings_tab.dart） =================
  Widget _buildSettingTab() {
    return SettingsTab(
      myDeviceName: _myDeviceName,
      localIp: _localIP,
      udpPort: _discovery.udpPort,
      // v2：展示实际 v2 HTTPS 服务端口
      tcpPort: _lsServer.boundPort,
      preferredUdpPort: _preferredUdpPort,
      preferredTcpPort: _preferredTcpPort,
      storagePathLabel: _storagePathLabel,
      tlsOnly: _tlsOnly,
      stealthMode: _stealthMode,
      visibility: _visibility,
      receivePin: _receivePin,
      onTlsOnlyChanged: _setTlsOnly,
      onStealthModeChanged: _setStealthMode,
      onPortChanged: _onPortChanged,
      onVisibilityChanged: _onVisibilityChanged,
      onReceivePinSave: _onReceivePinSave,
      onAddDeviceRequest: _onAddDeviceRequest,
      onStoragePathRequest: _onStoragePathSelected,
      onFixFirewallRequest: _fixFirewall,
      onResetIdentityRequest: _onResetIdentityConfirm,
      onDeleteAllDevicesRequest: _onDeleteAllDevicesConfirm,
    );
  }
}

/// v2：挂起的 prepare-upload 决策（一个会话一条）。
/// completer 由气泡按钮 / 接收对话框完成；发送方断开时由
/// onSessionEnd(aborted/cancelled) 兜底完成（LsDecline），防止泄漏。
class _LsPendingDecision {
  final LsIncomingRequest request;
  /// 对端身份键（指纹优先，回退 IP），气泡/缓存读写与 hook 推送共用。
  final String peerKey;
  final Completer<LsPrepareDecision> completer = Completer<LsPrepareDecision>();

  _LsPendingDecision(this.request, this.peerKey);
}

// ================= Windows 防火墙（镜像旧裸 TCP 服务实现） =================
// 旧文件传输服务计划第 8 步删除后，netsh 入站规则逻辑私有保留于此；
// 规则名保持 'WeChatLANTransfer'（与历史规则同名，重复添加幂等）。

const String _lsFirewallRuleName = 'WeChatLANTransfer';

/// 添加 Windows 防火墙入站规则（v2 TCP 接收通道 + legacy UDP 发现通道）。
/// 需要管理员权限（Windows 端经 manifest 提权，直接生效）。
Future<bool> _fixWindowsFirewall({
  int port = kLsDefaultPort,
  int udpPort = UdpMessageService.defaultMsgPort,
}) async {
  if (!Platform.isWindows) return true;

  Future<bool> addRule({
    required String name,
    required String protocol,
    required int localPort,
  }) async {
    try {
      final result = await Process.run('netsh', [
        'advfirewall',
        'firewall',
        'add',
        'rule',
        'name=$name',
        'dir=in',
        'action=allow',
        'protocol=$protocol',
        'localport=$localPort',
        'profile=any',
      ]);
      if (result.exitCode == 0) {
        debugPrint('[Firewall] $name 已添加（或已存在）');
        return true;
      }
      debugPrint(
        '[Firewall] $name 添加失败: exitCode=${result.exitCode} stderr=${result.stderr}',
      );
      return false;
    } catch (e) {
      debugPrint('[Firewall] $name 异常: $e');
      return false;
    }
  }

  final tcpOk = await addRule(
    name: '$_lsFirewallRuleName-TCP',
    protocol: 'TCP',
    localPort: port,
  );
  final udpOk = await addRule(
    name: '$_lsFirewallRuleName-UDP',
    protocol: 'UDP',
    localPort: udpPort,
  );
  return tcpOk && udpOk;
}
