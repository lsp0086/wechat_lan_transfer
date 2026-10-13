import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:archive/archive.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path/path.dart' as pth;
import '../Model/chat_model.dart';
import '../Transfer/ls_client.dart';
import '../Transfer/ls_dto.dart';
import '../Transfer/ls_server.dart';
import '../Transfer/file_utils.dart';
import '../Services/tls_identity_service.dart';
import '../Services/folder_archive_service.dart';
import '../Services/transfer_id.dart';
import '../Services/media_type.dart';
import '../Services/session_tracker.dart';
import '../Services/message_cache_service.dart';
import '../Services/udp_message_service.dart';
import '../Services/audio_service.dart';
import 'audio_bubble.dart';
import 'chat_more_page.dart';
import '../Services/toast_utils.dart';
import '../Services/cache_maintenance.dart';
import '../Services/transfer_texts.dart';
import '../Services/message_mutation.dart';
import '../Services/audio_format.dart';
import '../Services/extract_naming.dart';
import '../Services/history_paging.dart';
import '../Services/text_edit.dart';
import '../Services/text_inbound.dart';
import '../Services/online_check.dart';
import '../Services/file_icon.dart';
import '../Services/message_actions.dart';
import '../Services/transfer_state_map.dart';
import '../Services/device_lookup.dart';
import '../Services/file_size_format.dart';
import '../Services/ack_decision.dart';
import '../Services/cancel_texts.dart';
import '../Services/peer_identity.dart';
import '../Services/text_retry_policy.dart';
import '../Services/bubble_meta.dart';
import '../Services/send_naming.dart';
import '../Services/send_waiting_texts.dart';
import '../Services/media_layout.dart';
import '../Services/action_bubble_layout.dart';
import '../Services/file_location_command.dart';
import '../Services/blocked_list.dart';
import '../Services/pick_classify.dart';
import '../Services/app_config_store.dart';
import '../Services/emoji_bubble_texts.dart';
import '../Services/message_factory.dart';
import '../Services/lan_utils.dart';
import '../Services/record_policy.dart';
import '../Services/transfer_limits.dart';
import '../Services/send_dispatch.dart';
import '../Services/platform_info.dart';
import '../Services/text_send_queue.dart';
import '../Services/image_existence_cache.dart';
import '../Services/record_ui.dart';
import '../Services/chat_recovery.dart';
import '../Services/chat_debug_logs.dart';
import '../Services/app_clock.dart';
import '../Services/delay_policy.dart';
import 'chat_info_page.dart';

/// flutter_image_compress 原生实现仅支持 Android/iOS/macOS。
/// Windows/Linux/Web 上该插件虽可编译但调用会抛 MissingPluginException。
/// U6：桌面端降级原图直发（_generateThumbnail 返回 null 即用原图，不抛异常）。
/// E1：判定抽至 media_layout.isThumbCompressSupported。
bool get _isImageCompressSupported => isThumbCompressSupported(
      isAndroid: Platform.isAndroid,
      isIOS: Platform.isIOS,
      isMacOS: Platform.isMacOS,
    );

// E1：统一发送动作类型上移至 send_dispatch.SendActionType（避免循环依赖），
// 此处经 export 兼容存量引用。
// P1-3 文字队列条目抽至 text_send_queue.QueuedText/TextSendQueue（可单测）。

class ChatPage extends StatefulWidget {
  final String title;
  final String id;

  /// P0-7/P1-1：当前路由 IP（发送 UDP/TCP 用）。id 是身份键，可能是 deviceId。
  final String peerIp;

  /// P1-1：对端 v2 HTTPS 端口（来自发现广播；默认 LocalSend 53317）
  final int peerTcpPort;
  final UdpMessageService msgService;
  final String myDeviceName;

  /// v2 接收服务（ChatListPage 全局唯一实例，传入用于组装本端设备信息）
  final LsServer lsServer;

  /// v2 接收镜像 hook：chat_list 在 prepare-upload 决策/进度/结果落定时
  /// 按设备键推送气泡更新，打开中的 ChatPage 据此同步 UI
  /// （键 = 对端指纹优先，回退对端 IP；仅当前对话页注册，dispose 时注销）。
  static final Map<String, void Function(ChatMessage msg, bool isNew)>
      incomingFileHooks = {};

  /// v2 对端取消回执 hook：chat_list 收到 /cancel 时按设备键转发 sessionId。
  static final Map<String, void Function(String sessionId)> cancelSendHooks =
      {};

  /// 自动接收文件状态（从 ChatListPage 同步，仅用于 UI 展示）
  final bool initialAutoReceive;

  /// 自动接收状态变更回调（ChatInfoPage 修改后通知 ChatListPage 持久化）
  final void Function(bool value)? onAutoReceiveChanged;

  /// 用户手动点击接收文件的回调（通知 ChatListPage 发送 file_accept）
  /// P0-4：透传 transferId，解决同名并发顶掉；为空时兼容旧 fileName 路径。
  /// T2：透传 sessionId，会话级一次同意，后到同批自动沿用。
  final void Function(
    String targetIp,
    String fileName,
    String? transferId, {
    String? sessionId,
  })? onManualAcceptFile;

  /// 用户手动点击拒绝文件的回调（通知 ChatListPage 发送 file_reject）
  /// T2：透传 sessionId，会话级一次拒绝管整批。
  final void Function(
    String targetIp,
    String fileName,
    String? transferId, {
    String? sessionId,
  })? onManualRejectFile;

  /// P1-T7：文字最终发送失败回调（ChatList 入离线队列，对端上线重推）。
  final void Function(String msgId, String text)? onTextSendFailed;

  /// U2：从其他 App 分享进来的初始待发送内容（设备选择后进入本页自动发送）。
  final String? initialPendingText;

  /// U2：分享/拖拽进来的初始待发送文件（单文件直发，多文件走批量会话）。
  final List<String> initialPendingFilePaths;

  /// U2：拖拽进来的文件夹（打包 zip → isFolder 发送，接收端自动解压）。
  final String? initialPendingFolderPath;

  const ChatPage({
    super.key,
    required this.id,
    required this.title,
    required this.msgService,
    required this.myDeviceName,
    required this.lsServer,
    this.peerIp = '',
    this.peerTcpPort = kLsDefaultPort,
    this.initialAutoReceive = false,
    this.onAutoReceiveChanged,
    this.onManualAcceptFile,
    this.onManualRejectFile,
    this.onTextSendFailed,
    this.initialPendingText,
    this.initialPendingFilePaths = const [],
    this.initialPendingFolderPath,
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

/// v2 发送单条目快照：气泡已建/已更（pending 态），等待进入协议会话。
/// 一个会话可携带多个条目（批量多图）；取消令牌/会话 ID 以 msgId 为键。
class _LsSendItem {
  final String msgId;
  final String filePath;
  final String fileName; // 传给对端的原始名（文件夹为 xxx.zip）
  final int fileSize;
  final String? sha256;
  final bool isImage;
  final bool isFolder;
  final bool isVoice;
  final int durationMs;
  final String? waveformData;
  final String errLabel; // 失败文案前缀（📁/📤）
  final String displayName; // 去 .zip 后缀的展示名

  const _LsSendItem({
    required this.msgId,
    required this.filePath,
    required this.fileName,
    required this.fileSize,
    required this.sha256,
    required this.isImage,
    required this.isFolder,
    required this.isVoice,
    required this.durationMs,
    required this.waveformData,
    required this.errLabel,
    required this.displayName,
  });
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  List<ChatMessage> chatData = [];
  List<String> _emojiList = [];
  bool _isVoice = false;
  bool _isMore = false;
  bool _emojiState = false;

  final TextEditingController _textController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  // E3：先显示最近一页，滚到顶再往前补，避免一次渲染全部历史。
  // E1：分页大小直调 transfer_limits.kHistoryPageSize。
  bool _historyHasMore = false;
  bool _loadingOlder = false;

  // 服务层
  final MessageCacheService _cacheService = MessageCacheService();
  final ImagePicker _imagePicker = ImagePicker();
  final AudioService _audioService = AudioService();
  // E1/新库：传输/会话 ID 工厂（uuid v4 去碰撞，legacy 键格式保留兼容）。
  final TransferIdFactory _ids = TransferIdFactory();

  /// P0-7/P1-1：发送用当前路由 IP；peerIp 为空时回退 id（legacy：id 即 IP）
  /// S5：文字加密用对端指纹——id 为 64 位指纹时直接用，否则视为旧端无加密。
  /// E1：抽至 peer_identity.resolveTargetIp/resolvePeerFingerprint。
  String get _targetIp =>
      resolveTargetIp(peerIp: widget.peerIp, id: widget.id);

  String? get _peerFingerprint => resolvePeerFingerprint(widget.id);

  // 录音状态
  bool _isRecording = false;
  int _recordDurationMs = 0;
  Timer? _recordTimer;
  // 录音振幅采样：实时 UI 仅留 30 个，全程样本用于最终真波形（P1-7）
  final List<double> _recordAmplitudes = [];
  final List<double> _recordWaveformSamples = [];
  StreamSubscription<double>? _recordStateSub;

  // 录音遮罩相关
  bool _showRecordMask = false;
  bool _isCancelling = false;
  bool _isRecordGestureActive = false;

  // 自动接收文件（从 ChatListPage 同步，仅用于 UI 显示控制；缺省 false，P0-S7）
  bool _autoReceive = false;
  // 黑名单（默认关闭），从 ChatInfoPage 同步
  bool _isBlocked = false;
  // 对方是否拉黑了我（通过 blockSync 包获知）
  bool _isBlockedByPeer = false;

  // 缩略图缓存目录
  String? _thumbnailDir;

  // 消息重传机制：msgId -> Timer，用于等待 ACK 超时重发
  final Map<String, Timer> _pendingAcks = {};
  // 消息重传计数：msgId -> 已重试次数
  final Map<String, int> _retryCount = {};
  // E1：上限直调 transfer_limits.kMaxTextRetries（去上帝类别名_static _maxRetries）。

  /// P1-3：ACK 基础超时，指数退避 0.8s / 1.6s / 3.2s / 6.4s
  /// E1：直调 transfer_limits.kAckBaseTimeoutMs（去别名）。

  /// P1-3：心跳在此窗口内视为在线，跳过 ping，避免弱网发送卡 4s+
  /// E1：直调 transfer_limits.kFreshHeartbeatSec（去别名）。

  /// P1-3：发送队列相邻两条最小间隔，避免 UDP 突发
  /// E1：直调 transfer_limits.kTextSendGapMs（去别名）。

  /// P1-3：接收端 msgId 去重窗口
  /// E1：直调 transfer_limits.kRecvDedupTtlSec（去别名）。

  final TextSendQueue _textQueue = TextSendQueue();

  /// 接收侧近期 msgId（ChatPage 内存去重，避免 chatData 全表扫描）
  final Map<String, DateTime> _recentRecvMsgIds = {};

  // 图片尺寸/存在性缓存（E1：抽至 image_existence_cache.ImageExistenceCache）。
  final ImageExistenceCache _imgCache = ImageExistenceCache();
  // 传输进度节流：msgId/taskId -> 上次更新毫秒时间
  final Map<String, int> _lastProgressTick = {};

  // v2 发送会话映射：气泡 msgId -> 取消令牌 / 协议会话 ID
  // （取消按钮、对端 /cancel 回查用；终态后移除）
  final Map<String, LsCancelToken> _lsCancelByMsgId = {};
  final Map<String, String> _lsSessionByMsgId = {};
  static const int _maxExtractTotalSize = kMaxExtractTotalBytes;
  static const int _maxZipFileSize = kMaxZipFileBytes;
  static const int _maxThumbFiles = kMaxThumbFiles;

  // 消息长按动作气泡（复制 / 文件位置等）
  OverlayEntry? _actionBubbleEntry;
  StreamSubscription<ReceivedMessage>? _msgSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 注册 v2 接收/取消镜像 hook（chat_list 按设备键转发；
    // 双键兼容指纹与 IP 两种 id 形态）
    ChatPage.incomingFileHooks[widget.id] = _onIncomingFileFromPeer;
    ChatPage.cancelSendHooks[widget.id] = _onSendCancelledByPeer;
    final hookFp = _peerFingerprint;
    if (isNotNull(hookFp)) {
      ChatPage.incomingFileHooks[requireNonNullHint(hookFp)] =
          _onIncomingFileFromPeer;
      ChatPage.cancelSendHooks[requireNonNullHint(hookFp)] =
          _onSendCancelledByPeer;
    }

    // 精选常用 emoji，避免 Unicode 空白区间产生空表情
    _emojiList = _buildEmojiList();

    // 监听焦点变化：键盘弹起时自动收起面板
    _focusNode.addListener(_onFocusChanged);

    // fire-and-forget 异步初始化，异常不应崩溃整个页面
    _initChat().catchError((e, st) {
      // E1：初始化异常日志收敛至 chat_debug_logs.initChatFailLog。
      debugPrint(initChatFailLog(e, st));
    });
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    // 键盘高度变化时，滚动列表到底部以确保最新消息可见
    // E1：抽至 platform_info.isKeyboardVisible。
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    if (isKeyboardVisible(bottomInset)) {
      // 键盘弹起，延迟一帧滚动确保布局已更新
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom();
      });
    }
  }

  // 额外：面板切换时主动 unfocus/requestFocus 会触发焦点回调，
  // 用标记抑制回环，避免键盘反复弹起
  bool _panelSwitching = false;

  void _onFocusChanged() {
    if (_panelSwitching) return;
    if (_focusNode.hasFocus &&
        (_emojiState || _isMore || _isVoice)) {
      setState(() {
        _emojiState = false;
        _isMore = false;
        _isVoice = false;
      });
    }
  }

  /// 额外：传输进行中返回上一页时弹确认
  Future<bool> _confirmLeaveDuringTransfer() async {
    // E1：存在判定抽至 ack_decision.hasActiveMessage（纯函数可单测）。
    final active = hasActiveMessage(
      chatData,
      (m) => m.transferState,
      isActiveMsgState,
    );
    if (!active) return true;
    // E1：文案抽至 emoji_bubble_texts.leaveConfirmTexts。
    final t = leaveConfirmTexts();
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.title),
        content: Text(t.content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.stay),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: Text(t.leave),
          ),
        ],
      ),
    );
    // E1：回退抽至 bubble_meta.leaveResultOrStay。
    return leaveResultOrStay(result);
  }

  Future<void> _initChat() async {
    // 0. 从 ChatListPage 获取初始自动接收状态（已持久化在 ChatListPage 管理）
    _autoReceive = widget.initialAutoReceive;
    // 0.1 加载黑名单状态
    await _loadBlockedState();

    // 0.1 初始发送一次拉黑状态同步包（best-effort，UDP 可能丢包；
    // 最终由 ACK blocked 标记保证可靠同步 — 方案2）
    widget.msgService.sendBlockSync(targetIp: _targetIp, blocked: _isBlocked);

    // 1. 初始化缩略图目录
    try {
      final docDir = await getApplicationDocumentsDirectory();
      // E1：缩略图目录拼接收敛至 media_layout.buildThumbnailDirPath/shouldCreateThumbnailDir。
      _thumbnailDir = buildThumbnailDirPath(docDir.path);
      // E1：!收敛至 send_naming.requireThumbDir。
      final thumbDir = Directory(requireThumbDir(_thumbnailDir));
      if (shouldCreateThumbnailDir(exists: await thumbDir.exists())) {
        await thumbDir.create(recursive: true);
      }
      // P1-10：启动时做缩略图 LRU（超量删最旧），避免无限堆积
      unawaited(_pruneThumbnails());
    } catch (e) {
      // E1：缩略图目录日志收敛至 chat_debug_logs.thumbDirFailLog。
      debugPrint(thumbDirFailLog(e));
      _thumbnailDir = null;
    }
    // P1-10：清理 temp 目录下超过 24h 的残留 zip（打包/发送异常残留）
    unawaited(_cleanupStaleTempZips());
    // D3：清理 7 天以上语音/图片陈旧缓存
    unawaited(_cleanupStaleCache());

    // 2. 先设置监听（缓冲模式），防止缓存加载期间事件丢失
    // Broadcast stream 不缓存旧事件，监听必须在事件产生前就位
    // v2：文件接收/进度统一由 ChatListPage 处理后经静态 hook 推送，
    // 本页只订阅 UDP 消息流（文字/ACK/blockSync/fileMeta）
    final initEventBuffer = <dynamic>[];
    bool chatLoaded = false;

    _msgSubscription = widget.msgService.messageStream.listen((msg) {
      if (!chatLoaded) {
        initEventBuffer.add(msg);
        // E1：缓冲日志收敛至 chat_debug_logs.bufferedMsgLog。
        debugPrint(bufferedMsgLog('${msg.cmd}'));
        return;
      }
      _handleIncomingMessage(msg);
    });

    // 3. 从缓存加载聊天记录（E3：只取最近一页）
    var cachedMessages = await _cacheService.loadMessages(
      widget.id,
      limit: kHistoryPageSize,
    );
    final total =
        // E1：总数收敛至 session_tracker.totalCount。
        totalCount(await _cacheService.loadMessages(widget.id));
    // E1：更多判定抽至 history_paging.hasMoreHistory。
    _historyHasMore = hasMoreHistory(
      total: total,
      loaded: cachedMessages.length,
    );
    // 清理历史遗留的系统初始化消息
    // E1：过滤抽至 history_paging.withoutInitMessages。
    // E1：快照数收敛至 session_tracker.snapshotCount。
    final originalCount = snapshotCount(cachedMessages);
    cachedMessages = withoutInitMessages(cachedMessages, (m) => m.id);
    // E1：过滤命中判定抽至 history_paging.hasFilteredInitMessages。
    if (hasFilteredInitMessages(before: originalCount, after: cachedMessages.length)) {
      await _cacheService.saveMessages(widget.id, cachedMessages);
    }
    // E1：非空门控抽至 text_edit.isNonEmptyList。
    if (isNonEmptyList(cachedMessages)) {
      // 从缓存恢复后，将所有传输中/pending/sending 的消息标记为中断
      // 但接收到的文件如果磁盘上确实存在，说明传输已实际完成（ChatPage 关闭期间完成），
      // 标记为 completed 并触发追认解压
      bool hasChanges = false;
      final fixedMessages = <ChatMessage>[];
      for (final m in cachedMessages) {
        // E1：恢复决策抽至 chat_recovery.decideRecoveryAction（可单测）。
        final action = decideRecoveryAction(
          state: m.transferState,
          isMe: m.isMe,
          type: m.type,
          hasPath: hasFilePath(m.filePath),
          isFolder: m.isFolder,
        );
        // E1：活动态判定抽至 transfer_state_map.isActiveMsgState。
        // E1：恢复修复动作收敛至 chat_recovery.isRecoveryFixAction。
        if (isRecoveryFixAction(action)) {
          hasChanges = true;
          // 接收到的文件（非文字、非自己发的）：如果文件/文件夹已在磁盘上，视为已完成
          // E1：路径存在收敛至 send_naming.hasFilePath。
          // E1：==收敛至 chat_recovery.isRecoverCompletedAction。
          if (isRecoverCompletedAction(action) &&
              hasFilePath(m.filePath)) {
            // E1：!收敛至 send_naming.requireMsgPath。
            final path = requireMsgPath(m.filePath);
            final fileExists = await File(path).exists();
            final dirExists = await Directory(path).exists();
            // E1：追认门控抽至 chat_recovery.shouldRecoverCompleted。
            if (shouldRecoverCompleted(
              fileExists: fileExists,
              dirExists: dirExists,
            )) {
              // E1：追认日志收敛至 chat_debug_logs.recoveredLog。
              debugPrint(recoveredLog(m.fileName));
              // E1：追认文案抽至 TransferTexts.recoveredContent。
              // E1：完成变异收敛至 TransferTexts.markRecovered。
              final completed = TransferTexts.markRecovered(
                m,
                TransferTexts.recoveredContent(
                  isFolder: m.isFolder,
                  // E1：文件名兜底收敛至 send_naming.fileNameOrEmpty。
                  fileName: fileNameOrEmpty(m.fileName),
                ),
              );
              fixedMessages.add(completed);
              // 如果是文件夹，触发追认解压（fire-and-forget）
              if (m.isFolder) {
                _extractReceivedZip(
                  // E1：!收敛至 send_naming.requireMsgPath。
                  requireMsgPath(m.filePath),
                  // E1：文件名兜底抽至 send_naming.fileNameOrFolder。
                  fileNameOrFolder(m.fileName),
                  completed,
                );
              }
              continue;
            }
          }
          // 其他情况：标记为中断
          // E1：中断文案抽至 TransferTexts.interruptedContent。
          final newContent = TransferTexts.interruptedContent(
            // E1：音频判定收敛至 bubble_meta.isAudioMessageType。
            isAudio: isAudioMessageType(m.type.name),
            // E1：文字判定收敛至 bubble_meta.isTextMessageType。
            isText: isTextMessageType(m.type.name),
            isMe: m.isMe,
            content: m.content,
            // E1：文件名兜底收敛至 send_naming.fileNameOrEmpty。
            fileName: fileNameOrEmpty(m.fileName),
          );
          fixedMessages.add(
            // E1：失败变异收敛至 TransferTexts.markInterrupted。
            TransferTexts.markInterrupted(m, newContent),
          );
        } else {
          // 已完成的消息：如果是收到的文件夹且文件/文件夹存在，确保已解压
          // E1：门控抽至 chat_recovery.decideRecoveryAction（checkPostExtract）。
          // E1：==收敛至 chat_recovery.isCheckPostExtractAction。
          if (isCheckPostExtractAction(action)) {
            // E1：!收敛至 send_naming.requireMsgPath。
            final path = requireMsgPath(m.filePath);
            final fileExists = await File(path).exists();
            final dirExists = await Directory(path).exists();
            // E1：追认门控抽至 chat_recovery.shouldRecoverCompleted。
            if (shouldRecoverCompleted(
              fileExists: fileExists,
              dirExists: dirExists,
            )) {
              // 检查解压目标文件夹是否不存在（未解压过）
              // E1：基名去 zip 抽至 extract_naming.extractFolderBase。
              // E1：文件名兜底抽至 send_naming.fileNameOrFolder。
              final folderName = extractFolderBase(fileNameOrFolder(m.fileName));
              final parentDir = pth.dirname(path);
              final targetDir = Directory(pth.join(parentDir, folderName));
              if (!await targetDir.exists()) {
                // E1：追认解压日志收敛至 chat_debug_logs.recoveredZipLog。
                debugPrint(recoveredZipLog(m.fileName));
                // E1：文件名兜底抽至 send_naming.fileNameOrFolder。
                _extractReceivedZip(path, fileNameOrFolder(m.fileName), m);
              }
            }
          }
          fixedMessages.add(m);
        }
      }
      setState(() {
        chatData = fixedMessages;
      });
      if (hasChanges) {
        await _cacheService.saveMessages(widget.id, fixedMessages);
      }
    } else {
      setState(() {
        chatData = [];
      });
    }
    _scrollToBottom();

    // 4. 标记加载完成，处理缓冲的事件
    chatLoaded = true;
    // E1：非空门控抽至 text_edit.isNonEmptyList。
    if (isNonEmptyList(initEventBuffer)) {
      // E1：缓冲事件日志收敛至 chat_debug_logs.bufferedEventsLog。
      debugPrint(bufferedEventsLog(initEventBuffer.length));
      for (final event in initEventBuffer) {
        if (event is ReceivedMessage) {
          _handleIncomingMessage(event);
        }
      }
      initEventBuffer.clear();
    }

    // 5. TCP 服务器由 ChatListPage 全局管理，此处不再启动

    // 6. U2：从其他 App 分享/拖拽进来的初始待发送内容（缓冲/加载完毕后自动发送）。
    // E1：门控抽至 text_edit.hasPendingText/Paths/Folder，批量元组抽至 pick_classify。
    final pendingText = widget.initialPendingText;
    if (hasPendingText(pendingText)) {
      // E1：!收敛至 send_naming.requirePendingText。
      await _handleSubmittedData(requirePendingText(pendingText));
    }
    final pendingPaths = widget.initialPendingFilePaths;
    if (hasPendingPaths(pendingPaths)) {
      if (isSinglePathBatch(pendingPaths.length)) {
        await _trySend(
          type: SendActionType.file,
          filePath: pendingPaths.first,
          // E1/新库：文件名取 basename（path 包，跨平台分隔符）。
          fileName: pth.basename(pendingPaths.first),
        );
      } else {
        // T2：多文件走批量会话（一次同意管整批）。
        // E1：元组抽至 pick_classify.buildBatchTuples。
        await _sendBatchFiles(
          buildBatchTuples(pendingPaths, pth.basename, isImageFileName),
        );
      }
    }
    final pendingFolder = widget.initialPendingFolderPath;
    // E1：门控抽至 text_edit.hasPendingFolder。
    if (hasPendingFolder(pendingFolder)) {
      // E1：!收敛至 send_naming.requirePendingFolder。
      await _sendFolderByPath(requirePendingFolder(pendingFolder));
    }
  }

  // ========== 处理 UDP 消息通道的入站消息 ==========
  void _handleIncomingMessage(ReceivedMessage msg) {
    // E1：入站日志收敛至 chat_debug_logs.inboundLog。
    debugPrint(inboundLog(msg.cmd, msg.senderIp, widget.id));
    // 只处理来自当前对话设备的消息（用于 UI 显示和文件协商）
    // 当 widget.id 无效时（空或 0.0.0.0 历史 bug），跳过过滤以保底
    // 消息缓存由 ChatListPage 全局处理，此处不做重复缓存
    // E1：抽至 peer_identity.shouldIgnoreIncoming/isDeviceIdValid。
    final bool idValid = isDeviceIdValid(widget.id);
    if (shouldIgnoreIncoming(
      deviceId: widget.id,
      peerIp: widget.peerIp,
      targetIp: _targetIp,
      senderIp: msg.senderIp,
    )) {
      // E1：忽略日志收敛至 chat_debug_logs.ignoreMsgLog。
      debugPrint(ignoreMsgLog(msg.senderIp, widget.id, _targetIp));
      return;
    }
    if (!idValid) {
      // E1：无效 id 日志收敛至 chat_debug_logs.invalidIdLog。
      debugPrint(invalidIdLog(widget.id));
    }

    // 已拉黑：拒收文本消息
    if (_isBlocked) {
      // E1：文案抽至 send_waiting_texts.blockedAndRejectedText。
      showCenterToast(context, blockedAndRejectedText());
      // E1：文字命令收敛至 text_inbound.isTextCmd。
      if (isTextCmd(msg.cmd.name)) {
        // E1：ID抽至 text_inbound.parseInboundMsgId。
        final msgId = parseInboundMsgId(msg.payload);
        if (hasInboundMsgId(msgId)) { // E1：入站ID委托
          widget.msgService.sendMsgAck(
            targetIp: msg.senderIp,
            // E1：!收敛至 text_inbound.requireNonNullHint（已判空复用）。
            msgId: requireNonNullHint(msgId),
            blocked: true,
          );
        }
      }
      return;
    }
    // v2 文件接收（prepare-upload/进度/结果）由 ChatListPage 统一处理后经 hook 推送

    switch (msg.cmd) {
      case UdpCmd.textMessage:
        _onTextMessageReceived(msg);
        break;
      case UdpCmd.msgAck:
        _onMsgAckReceived(msg);
        break;
      case UdpCmd.blockSync:
        _onBlockSyncReceived(msg);
        break;
      case UdpCmd.fileMeta:
      case UdpCmd.ping:
      case UdpCmd.pong:
        // fileMeta 旁路元数据由 ChatListPage 统一消费；ping/pong 上层已处理
        break;
    }
  }

  /// 收到文字消息
  void _onTextMessageReceived(ReceivedMessage msg) {
    // S5：cipher 优先解密；失败则保留占位文并标记，避免乱码入库。
    // E1：内容回退+ID 生成抽至 text_inbound（纯函数可单测）。
    final decrypted = UdpMessageService.decryptIncomingText(msg.payload);
    final content = resolveInboundTextContent(
      decrypted: decrypted,
      payload: msg.payload,
    );
    // E1：ID抽至 text_inbound.parseInboundMsgId。
    final msgId = parseInboundMsgId(msg.payload);

    // P1-3：内存去重窗口 + chatData 兜底，拦截重试风暴
    // E1：重复丢弃收敛至 text_inbound.shouldDropDuplicate。
    if (shouldDropDuplicate(
      msgId,
      // E1：非空判定委托至 text_edit.isNotNull（!收敛至requireNonNullHint保提升）。
      isNotNull(msgId) && _isRecvDuplicate(requireNonNullHint(msgId)),
    )) {
      // E1：重复消息日志收敛至 chat_debug_logs.duplicateMsgLog。
      debugPrint(duplicateMsgLog(msgId));
      return;
    }

    // E1：构造抽至 message_factory.buildIncomingText。
    final newMsg = buildIncomingText(
      id: inboundTextMessageId(
        msgId: msgId,
        nowMs: nowMs() /* E1：时钟收敛至 app_clock.nowMs */,
      ),
      senderId: msg.senderIp,
      content: content,
      now: now() /* E1：时钟收敛至 app_clock.now */,
    );

    setState(() {
      // E1：列表变异收敛至 message_mutation（append/prepend/replace返回新List）。
      chatData = appendMessage(chatData, newMsg);
    });
    // P1-4：入站文字由 ChatList 单写缓存，此处只刷 UI
    _scrollToBottom();
  }

  // ========== v2 接收镜像（ChatListPage 经静态 hook 推送，本页仅刷 UI） ==========

  /// ChatListPage 推送的接收气泡：isNew=true 追加，否则按确定性 id 原位替换。
  /// 缓存由 ChatListPage 统一写，这里只更新内存列表，并在到达完成态时补全元数据。
  void _onIncomingFileFromPeer(ChatMessage msg, bool isNew) {
    final idx = findFirstIndexById(chatData, (m) => m.id, msg.id);
    if (isNew && isMissingIndex(idx)) {
      if (!mounted) return;
      setState(() {
        chatData = appendMessage(chatData, msg);
      });
      _scrollToBottom();
    } else if (hasFoundIndex(idx)) {
      if (!mounted) return;
      setState(() {
        chatData = replaceAt(chatData, idx, msg);
      });
    } else {
      return;
    }
    // 完成态触发元数据补全（文件夹解压 / 图片缩略图 / 语音元数据）
    if (msg.transferState == TransferState.completed) {
      unawaited(_fillMetaAfterLsReceive(msg));
    }
  }

  /// 接收气泡完成后的元数据补全（对齐旧 TCP 流程的追认逻辑）。
  Future<void> _fillMetaAfterLsReceive(ChatMessage msg) async {
    // 文件夹：zip 已落盘，解压为目录（解压后气泡内部自行更新缓存）
    if (msg.isFolder) {
      if (canExtractZip(msg.filePath, msg.fileName)) {
        await _extractReceivedZip(
          requireMsgPath(msg.filePath),
          requireNonNullHint(fileNameOrFolder(msg.fileName)),
          msg,
        );
      }
      return;
    }
    // 图片：异步生成缩略图并回填
    if (isImageMessageType(msg.type.name)) {
      final imagePath = resolveImagePathFallback(msg.imagePath, msg.filePath);
      if (hasImagePath(imagePath)) {
        _generateThumbnail(
          requireMsgPath(imagePath),
          fileNameOrImage(msg.fileName),
        ).then((thumbPath) {
          final idx = findFirstIndexById(chatData, (m) => m.id, msg.id);
          if (shouldApplyThumbnail(
            thumbPath: thumbPath,
            mounted: mounted,
            index: idx,
          )) {
            final msgWithThumb =
                TransferTexts.markThumbnail(chatData[idx], thumbPath);
            setState(() {
              chatData = replaceAt(chatData, idx, msgWithThumb);
            });
          }
        });
      }
      return;
    }
    // 语音：元数据旁路缺失时兜底补全（旧端/异常路径兼容）
    if (isAudioMessageType(msg.type.name) &&
        TransferTexts.needsAudioMetaFill(
          durationMs: msg.durationMs,
          waveformData: msg.waveformData,
        )) {
      final audioPath = msg.filePath;
      if (audioPath != null) {
        _updateAudioMeta(audioPath, msg);
      }
    }
  }

  /// 对端取消了我们的发送会话（ChatListPage 收到 /cancel 后转发 sessionId）：
  /// 先标记关联气泡“对方已取消”（终态保护），再中止本地 in-flight 请求。
  void _onSendCancelledByPeer(String sessionId) {
    final affected = <ChatMessage>[];
    setState(() {
      for (final entry in _lsSessionByMsgId.entries) {
        if (entry.value != sessionId) continue;
        final idx = findFirstIndexById(chatData, (m) => m.id, entry.key);
        if (isMissingIndex(idx)) continue;
        final old = chatData[idx];
        // 终态保护：已到完成/失败的结果不被取消覆盖
        if (shouldGuardTerminal(old.transferState)) continue;
        final cancelled = TransferTexts.markPeerCancel(
          old,
          peerCancelContent(
            isAudio: isAudioMessageType(old.type.name),
            isMe: old.isMe,
            fileName: fileNameOrEmpty(old.fileName),
          ),
        );
        chatData = replaceAt(chatData, idx, cancelled);
        affected.add(cancelled);
      }
      _lsSessionByMsgId.removeWhere((_, v) => v == sessionId);
    });
    // 中止本地请求放在 setState 外（终态已写，异步 catch 不会覆盖）
    for (final m in affected) {
      _lsCancelByMsgId.remove(m.id)?.cancel();
      _lastProgressTick.remove(m.id);
    }
    for (final m in affected) {
      _cacheService.updateMessage(widget.id, m.id, m);
    }
  }

  /// 收到消息 ACK 确认。
  /// 方案2核心：通过 ACK 同步拉黑状态，替代不可靠的 blockSync 单发包。
  /// - blocked ACK：保留消息气泡 → 标记 failed → 设置 _isBlockedByPeer → toast
  /// - 正常 ACK：标记 completed → 清除 _isBlockedByPeer（自愈：对方已解除拉黑）
  void _onMsgAckReceived(ReceivedMessage msg) {
    // E1：ID抽至 text_inbound.parseInboundMsgId。
    final msgId = parseInboundMsgId(msg.payload);
    // E1：空ID判定委托至text_edit（可单测）。
    if (isNullId(msgId)) return;
    // E1：!收敛至 text_inbound.requireNonNullHint（已判空复用）。
    final mid = requireNonNullHint(msgId);

    // 取消重传定时器
    // E1：取消抽至 text_retry_policy.cancelAckTimer。
    cancelAckTimer(_pendingAcks, _retryCount, mid, (t) => t.cancel());

    // E1：标志抽至 text_inbound.parseBlockedFlag。
    final blocked = parseBlockedFlag(msg.payload);

    // E1：ACK 匹配抽至 ack_decision.findAckIndex（纯函数可单测）。
    final index = findAckIndex(chatData, (m) => m.id, mid);
    if (hasFoundIndex(index)) /* E1：命中委托 */ {
      if (blocked) {
        // 对方拉黑了我：只对 sending 状态的消息标记失败
        // 已完成的消息不受影响（已发送成功的消息不因后续 block 而变化）
        // E1：门控抽至 ack_decision.shouldMarkBlockedFailed。
        if (shouldMarkBlockedFailed(chatData[index].transferState)) {
          // E1：ACK拒收日志收敛至 chat_debug_logs.ackBlockedLog。
          debugPrint(ackBlockedLog(msgId));
          setState(() {
            // E1：仅标failed沿用旧content，收敛至 TransferTexts.markFailedKeepContent。
            chatData = replaceAt(chatData, index, TransferTexts.markFailedKeepContent(
              chatData[index],
            ));
          });
          _cacheService.updateMessage(
            widget.id,
            chatData[index].id,
            chatData[index],
          );
          _isBlockedByPeer = true;
          // E1：文案抽至 send_waiting_texts.blockedByPeerText。
          _showCenterToast(blockedByPeerText());
        }
        // 已完成或已失败的消息：跳过，不做额外处理
      } else {
        // E1：ACK送达日志收敛至 chat_debug_logs.ackOkLog。
        debugPrint(ackOkLog(msgId));
        // sending → completed：正常确认送达
        // failed → completed：自愈恢复（blockSync 误标记时 ACK 到达纠正）
        // E1：门控抽至 ack_decision.shouldMarkAckCompleted。
        final currentState = chatData[index].transferState;
        if (shouldMarkAckCompleted(currentState)) {
          setState(() {
            // E1：完成变异收敛至 TransferTexts.markCompletedKeepContent。
            chatData = replaceAt(chatData, index, TransferTexts.markCompletedKeepContent(
              chatData[index],
            ));
          });
          _cacheService.updateMessage(
            widget.id,
            chatData[index].id,
            chatData[index],
          );
        }
        // 消息正常送达 → 对方没拉黑我，清除旧状态（自愈解除拉黑）
        if (_isBlockedByPeer) {
          // E1：自愈日志收敛至 chat_debug_logs.ackHealedLog。
          debugPrint(ackHealedLog());
          _isBlockedByPeer = false;
        }
      }
    }
  }

  // ========== 取消传输（v2：中止 in-flight 请求 + 尽力通知对端） ==========
  void _cancelTransfer(ChatMessage msg) {
    final token = _lsCancelByMsgId.remove(msg.id);
    final sessionId = _lsSessionByMsgId.remove(msg.id) ?? msg.sessionId;
    // 先中止本地请求：被 abort 的 prepare/upload 以“已取消”错误浮出，
    // 终态保护保证该异步 catch 不会覆盖下面写入的已取消气泡
    token?.cancel();
    _lastProgressTick.remove(msg.id);
    if (isNotNull(sessionId)) {
      // 尽力通知对端取消会话：
      // 发送中 → 对端释放接收槽；接收中 → 对端停止发送并标“对方已取消”
      unawaited(LsClient.instance.cancelSession(
        ip: _targetIp,
        port: widget.peerTcpPort,
        sessionId: requireNonNullHint(sessionId),
        expectedFingerprint: _peerFingerprint,
      ));
    }

    // E1：音频判定收敛至 bubble_meta.isAudioMessageType。
    final isAudio = isAudioMessageType(msg.type.name);
    setState(() {
      final index = findFirstIndexById(chatData, (m) => m.id, msg.id);
      if (hasFoundIndex(index)) /* E1：命中委托 */ {
        // 终态保护：已到完成/失败的结果不被取消覆盖
        if (shouldGuardTerminal(chatData[index].transferState)) return;
        // E1：文案抽至 cancel_texts.localCancelContent。
        // E1：失败变异收敛至 TransferTexts.markCancelLocal。
        chatData = replaceAt(chatData, index, TransferTexts.markCancelLocal(
          chatData[index],
          localCancelContent(
            isAudio: isAudio,
            isMe: chatData[index].isMe,
            // E1：文件名兜底收敛至 send_naming.fileNameOrEmpty。
            fileName: fileNameOrEmpty(chatData[index].fileName),
          ),
        ));
        _cacheService.updateMessage(widget.id, msg.id, chatData[index]);
      }
    });
  }

  // ========== pending 消息的接收/拒绝操作 ==========

  /// 小号操作按钮（接收/拒绝）
  Widget _buildMiniButton(String label, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.3), width: 0.5),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ),
    );
  }

  /// 用户点击 pending 消息的「接收」
  /// v2：转交 ChatListPage 完成对应 prepare-upload 的挂起决策（接受）
  void _onUserAcceptPending(ChatMessage msg) {
    // E1：文件名兜底收敛至 send_naming.fileNameOrEmpty。
    final fileName = fileNameOrEmpty(msg.fileName);
    // E1：用户接受日志收敛至 chat_debug_logs.userAcceptLog。
    debugPrint(userAcceptLog(fileName));
    // 通知 ChatListPage 完成挂起的 v2 决策（无在途决策时为 no-op）
    // E1：回调空安全调用留宿主（?.call透传，宿主直接调用）。
    widget.onManualAcceptFile?.call(
      widget.id,
      fileName,
      msg.transferId,
      sessionId: msg.sessionId,
    );
    // 更新本地消息为「等待传输中」
    // E1：文案抽至 TransferTexts.waitingContent。
    final index = findFirstIndexById(chatData, (m) => m.id, msg.id);
    if (hasFoundIndex(index)) /* E1：命中委托 */ {
      setState(() {
        // E1：等待变异收敛至 TransferTexts.markWaiting。
        chatData = replaceAt(chatData, index, TransferTexts.markWaiting(
          msg,
          TransferTexts.waitingContent(fileName),
        ));
      });
      _cacheService.updateMessage(widget.id, msg.id, chatData[index]);
    }
  }

  /// 用户点击 pending 消息的「拒绝」
  void _onUserRejectPending(ChatMessage msg) {
    // E1：文件名兜底收敛至 send_naming.fileNameOrEmpty。
    final fileName = fileNameOrEmpty(msg.fileName);
    // E1：用户拒绝日志收敛至 chat_debug_logs.userRejectLog。
    debugPrint(userRejectLog(fileName));
    // 标记消息为已拒绝
    // E1：文案抽至 TransferTexts.selfRejectContent。
    final index = findFirstIndexById(chatData, (m) => m.id, msg.id);
    if (hasFoundIndex(index)) /* E1：命中委托 */ {
      setState(() {
        // E1：失败变异收敛至 TransferTexts.markSelfReject。
        chatData = replaceAt(chatData, index, TransferTexts.markSelfReject(
          msg,
          TransferTexts.selfRejectContent(fileName),
        ));
      });
      _cacheService.updateMessage(widget.id, msg.id, chatData[index]);
    }
    // 通知 ChatListPage 发送 file_reject
    // E1：回调空安全调用留宿主（?.call透传，宿主直接调用）。
    widget.onManualRejectFile?.call(
      widget.id,
      fileName,
      msg.transferId,
      sessionId: msg.sessionId,
    );
  }

  // ========== 文件选择器 ==========
  Future<void> _openFilePicker() async {
    if (!await _checkTargetOnline()) return;

    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        // T2：允许多选，同一批共享 sessionId，会话级一次同意 + 队列逐个传输。
        allowMultiple: true,
      );

      // E1：result?.files复杂链留宿主（判空已收敛isEmptyPick，不动行为）。
      // E1：空选抽至 pick_classify.isEmptyPick（保留null短路以维持非空提升）。
      // E1：?.链收敛至 pick_classify.pickFilesOrNull/isNullPick。
      final files = pickFilesOrNull(result?.files)
          ?.where((f) => hasPickPath(f.path)) // E1：选择路径委托
          .toList();
      // E1：result?.files复杂链留宿主（判空已收敛isEmptyPick，不动行为）。
      // E1：空选抽至 pick_classify.isEmptyPick（保留null短路以维持非空提升）。
      if (isNullPick(files) || isEmptyPick(files)) return;
      // E1：单选判定抽至 pick_classify.isSinglePick。
      if (isSingleFilePick(requireExisting(files))) { // E1：单文件选择委托
        _trySend(
          type: SendActionType.file,
          // E1：!收敛至 send_naming.requireSinglePath。
          filePath: requireSinglePath(requireExisting(files).single.path),
          fileName: requireExisting(files).single.name,
        );
      } else {
        await _sendBatchFiles(
          requireExisting(files)
              .map(
                (f) => (
                  // E1：!收敛至 send_naming.requireSinglePath。
                  path: requireSinglePath(f.path),
                  name: f.name,
                  isImage: false,
                ),
              )
              .toList(),
        );
      }
    } catch (e) {
      // E1：文件选择日志收敛至 chat_debug_logs.pickFailLog。
      debugPrint(pickFailLog(e));
      if (mounted) {
        // E1：文案抽至 send_waiting_texts.filePickFailedText。
        showCenterToast(context, filePickFailedText(e));
      }
    }
  }

  /// 文件夹发送：选择文件夹后打包为 zip 并发送（类似 LocalSend 行为）。
  Future<void> _openFolderPicker() async {
    if (!await _checkTargetOnline()) return;

    // Android 11+ 需要 MANAGE_EXTERNAL_STORAGE 才能读取外部存储上的非应用目录
    if (Platform.isAndroid) {
      var status = await Permission.manageExternalStorage.status;
      if (!status.isGranted) {
        // request() 会跳转到系统设置页，让用户手动开启"所有文件访问权限"
        status = await Permission.manageExternalStorage.request();
        if (!status.isGranted) {
          if (mounted) {
            // E1：文案抽至 send_waiting_texts.folderAccessDeniedText。
            showCenterToast(context, folderAccessDeniedText());
          }
          return;
        }
      }
    }

    try {
      final String? folderPath = await FilePicker.platform.getDirectoryPath(
        dialogTitle: folderPickTitle(),
      );
      if (abortFolderSend(folderPath, mounted)) return; // E1：文件夹发送门控委托

      // U2/E1：打包+发送抽至 _sendFolderByPath（选择器与拖拽文件夹共用）。
      // E1：!收敛至 send_naming.requirePendingFolder。
      await _sendFolderByPath(requirePendingFolder(folderPath));
    } catch (e) {
      // E1：文件夹发送日志收敛至 chat_debug_logs.folderFailLog。
      debugPrint(folderFailLog(e));
      if (mounted) {
        // E1：文案抽至 send_waiting_texts.folderPickFailedText。
        showCenterToast(context, folderPickFailedText(e));
      }
    }
  }

  /// U2/E1：按路径发送文件夹（打包 zip → isFolder 发送，接收端自动解压）。
  /// 选择器与拖拽文件夹（desktop_drop）共用；P0-6 唯一临时名 + 失败清理。
  Future<void> _sendFolderByPath(String folderPath) async {
    final dir = Directory(folderPath);
    if (!await dir.exists()) {
      if (mounted) {
        // E1：文案抽至 send_waiting_texts.folderMissingText。
        showCenterToast(context, folderMissingText());
      }
      return;
    }

    // E1/新库：path.basename 跨平台取文件夹名。
    // E1：三件套抽至 send_naming.buildFolderZipPath。
    final tempDir = await getTemporaryDirectory();
    // P0-6：唯一临时名（防并发同名顶掉）+ 失败清理（finally 删残留）
    final zipParts = buildFolderZipPath(
      folderPath: folderPath,
      tempDirPath: tempDir.path,
      stampUs: nowUs() /* E1：时钟收敛至 app_clock.nowUs */,
      basename: pth.basename(folderPath),
    );
    final folderName = zipParts.folderName;
    final zipFileName = zipParts.zipFileName;
    final zipPath = zipParts.zipPath;
    File? zipFile;

    try {
      // P0-6：打包前只 stat 预检（不读内容），超限直接拒绝，避免全量进内存 OOM
      final packCheck = await _checkFolderPackable(dir);
      if (!packCheck.ok) {
        if (mounted) {
          showCenterToast(context, packCheck.message);
        }
        return;
      }

      // 打包文件夹为 zip
      final archive = Archive();
      await _addDirectoryToArchive(archive, dir, folderName);

      // E1：打包完成日志收敛至 chat_debug_logs.folderPackedLog。
      debugPrint(folderPackedLog(folderPath, folderName, archive.length));
      // E1：为空门控抽至 text_edit.isEmptyList。
      if (isEmptyList(archive)) {
        if (mounted) {
          // E1：文案抽至 send_waiting_texts.folderEmptyText。
          showCenterToast(context, folderEmptyText());
        }
        return;
      }

      // 写入 zip 文件
      final zipBytes = ZipEncoder().encode(archive);
      // E1：为空门控抽至 text_edit.isEmptyList。
      if (isEmptyList(zipBytes)) {
        if (mounted) {
          // E1：文案抽至 send_waiting_texts.folderPackFailedText。
          showCenterToast(context, folderPackFailedText());
        }
        return;
      }
      zipFile = File(zipPath);
      await zipFile.writeAsBytes(zipBytes);
      // E1：zip打包日志收敛至 chat_debug_logs.folderZippedLog。
      debugPrint(
        folderZippedLog(
          folderName,
          formatFileSize(zipBytes.length),
        ),
      );

      // 通过统一入口发送 zip（标记 isFolder，接收端自动解压）
      await _sendFileFromPath(zipPath, zipFileName, isFolder: true);
    } finally {
      // P0-6：发送完成后删除本地临时 zip（sendFile 已读完，残留不再需要）；
      // 失败/异常同样清理，避免 temp 目录堆积
      try {
        final f = resolveZipFile(zipFile, zipPath); // E1：zip回退委托
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  /// P0-6：打包前预检（只 stat 不读内容）：累计大小 / 单文件 / 文件数上限。
  /// 超限直接拒绝，避免 Archive + readAsBytes 全量进内存 OOM。
  /// E1：预检抽至 folder_archive_service（可单测，temp 目录）。
  Future<({bool ok, String message})> _checkFolderPackable(
    Directory dir,
  ) async {
    return FolderArchiveService.checkFolderPackable(
      dir,
      limits: const FolderArchiveLimits(
        maxPackTotalSize: kMaxPackTotalBytes,
        maxPackSingleFile: kMaxPackSingleBytes,
        maxPackFileCount: kMaxPackFileCount,
      ),
      describe: formatFileSize,
    );
  }

  /// E1：递归打包抽至 folder_archive_service（含空目录/系统垃圾过滤/超大兜底）。
  Future<void> _addDirectoryToArchive(
    Archive archive,
    Directory dir,
    String parentPath,
  ) async {
    await FolderArchiveService.addDirectoryToArchive(
      archive,
      dir,
      parentPath,
      limits: const FolderArchiveLimits(maxPackSingleFile: kMaxPackSingleBytes),
    );
  }

  // ========== 图片选择器（相册）- 用 file_picker 选择原始文件 ==========
  // 避免 image_picker 对 GIF 等格式重新编码导致模糊/丢失动画
  // E1：扩展名表抽至 pick_classify.galleryExtensions，单选判定抽至 isSinglePick。
  Future<void> _pickImageFromGallery() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: galleryExtensions(),
        // T2：图片同样允许多选，走批量会话一次同意。
        allowMultiple: true,
      );

      // E1：?.链收敛至 pick_classify.pickFilesOrNull/isNullPick。
      final files = pickFilesOrNull(result?.files)?.where((f) => hasPickPath(f.path)).toList(); // E1：选择路径委托
      // E1：result?.files复杂链留宿主（判空已收敛isEmptyPick，不动行为）。
      // E1：空选抽至 pick_classify.isEmptyPick（保留null短路以维持非空提升）。
      // E1：files == null收敛至 pick_classify.isNullPick。
      if (isNullPick(files) || isEmptyPick(files)) return;
      // E1：单选判定抽至 pick_classify.isSinglePick。
      if (isSingleFilePick(requireExisting(files))) { // E1：单文件选择委托
        _trySend(
          type: SendActionType.image,
          // E1：!收敛至 send_naming.requireSinglePath。
          filePath: requireSinglePath(requireExisting(files).single.path),
          fileName: requireExisting(files).single.name,
        );
      } else {
        await _sendBatchFiles(
          // E1：!收敛至 send_naming.requireSinglePath。
          requireExisting(files).map((f) => (path: requireSinglePath(f.path), name: f.name, isImage: true)).toList(),
        );
      }
    } catch (e) {
      // E1：图片选择日志收敛至 chat_debug_logs.imageFailLog。
      debugPrint(imageFailLog(e));
    }
  }

  // ========== 拍照 ==========
  Future<void> _takePhoto() async {
    try {
      final XFile? photo = await _imagePicker.pickImage(
        source: ImageSource.camera,
        imageQuality: 90,
      );

      final ph = photo;
      if (isNotNull(ph)) { // E1：非空判定委托
        _trySend(
          type: SendActionType.image,
          // E1：!收敛至 send_naming.requireSinglePath。
          // E1：?.链收敛至 pick_classify.pickPathOrNull。
          filePath: requireSinglePath(pickPathOrNull(ph?.path)),
          // E1：?.链收敛至 pick_classify.pickNameOrNull。
          fileName: pickNameOrNull(ph?.name),
        );
      }
    } catch (e) {
      // E1：拍照日志收敛至 chat_debug_logs.photoFailLog。
      debugPrint(photoFailLog(e));
    }
  }

  // ========== 发送文件（v2 LocalSend 协议） ==========
  /// T2：批量发送——先为每个文件建立 pending 气泡，再合并为一个 v2 会话
  /// （一次 prepare-upload 请求 → 接收方一次决策 → 逐文件 upload）。
  /// 失败单个标记失败不阻塞后续。
  Future<void> _sendBatchFiles(
    List<({String path, String name, bool isImage})> files,
  ) async {
    // E1：门控抽至 online_check.shouldAbortBatchSend。
    final online = await _checkTargetOnline();
    if (shouldAbortBatchSend(empty: files.isEmpty, online: online)) return;
    final items = <_LsSendItem>[];
    for (final f in files) {
      final item = await _prepareSendItem(f.path, f.name, isImage: f.isImage);
      if (item != null) items.add(item);
    }
    if (items.isEmpty) return;
    // 批量多图 = 一个 v2 会话多文件（接收方一次决策管整批）
    await _sendViaLs(items);
  }

  /// 单文件发送入口（文件/图片/文件夹 zip 共用；语音走 _sendAudioMessage）。
  Future<void> _sendFileFromPath(
    String filePath,
    String fileName, {
    bool isImage = false,
    bool isFolder = false,
    ChatMessage? existingMsg,
  }) async {
    final item = await _prepareSendItem(
      filePath,
      fileName,
      isImage: isImage,
      isFolder: isFolder,
      existingMsg: existingMsg,
    );
    if (item == null) return;
    await _sendViaLs([item]);
  }

  /// 发送前的就绪处理：存在检查 + size/sha256 预计算 + 缩略图 + 建/更气泡。
  /// 返回 null 表示文件缺失已处理（失败占位已写），调用方直接跳过。
  Future<_LsSendItem?> _prepareSendItem(
    String filePath,
    String fileName, {
    bool isImage = false,
    bool isFolder = false,
    bool isVoice = false,
    int durationMs = 0,
    String? waveformData,
    ChatMessage? existingMsg,
    // 语音重试：保持语音气泡文案（不写成文件等待文案）
    String? waitingContentOverride,
  }) async {
    // E1：重发判定收敛至 send_naming.isRetrySend。
    final isRetry = isRetrySend(existingMsg);
    // E1：命名抽至 send_naming.newSendMsgId/stripZipSuffixForDisplay/sendErrLabel。
    final msgId = newSendMsgId(
      isRetry: isRetry,
      existingId: nullableId(existingMsg?.id), // E1：?.链收敛至 send_naming.nullableId。
      nowMs: nowMs() /* E1：时钟收敛至 app_clock.nowMs */,
    );
    final displayName = stripZipSuffixForDisplay(fileName);
    final errLabel = sendErrLabel(isFolder: isFolder);
    String? thumbPath;

    final file = File(filePath);
    if (!await file.exists()) {
      // E1：缺文件日志收敛至 chat_debug_logs.sendMissingLog。
      debugPrint(sendMissingLog(filePath));
      if (mounted) {
        if (isRetry) {
          // 重用已有消息，更新为失败
          // E1：文案抽至 TransferTexts.fileDeletedContent。
          // E1：!收敛至 send_naming.requireExistingId。
          final idx = findFirstIndexById(chatData, (m) => m.id, requireExistingId(existingMsg?.id));
          if (hasFoundIndex(idx)) /* E1：命中委托 */ {
            // E1：失败变异收敛至 TransferTexts.markFileDeleted。
            final failMsg = TransferTexts.markFileDeleted(
              chatData[idx],
              TransferTexts.fileDeletedContent(
                errLabel: errLabel,
                displayName: displayName,
              ),
            );
            setState(() {
              chatData = replaceAt(chatData, idx, failMsg);
            });
            _cacheService.updateMessage(widget.id, requireExisting(existingMsg).id, failMsg);
          }
        } else {
          // E1：文案抽至 TransferTexts.fileDeletedContent，构造抽至 message_factory。
          // E1：ID 抽至 send_naming.newSendErrId。
          final errMsg = buildSendMissingFile(
            id: newSendErrId(nowMs() /* E1：时钟收敛至 app_clock.nowMs */),
            content: TransferTexts.fileDeletedContent(
              errLabel: errLabel,
              displayName: displayName,
            ),
            isImage: isImage,
            displayName: displayName,
            filePath: filePath,
            isFolder: isFolder,
            now: now() /* E1：时钟收敛至 app_clock.now */,
          );
          setState(() {
            chatData = appendMessage(chatData, errMsg);
          });
          _cacheService.appendMessage(widget.id, errMsg);
          _scrollToBottom();
        }
      }
      return null;
    }
    // E1：大小委托至 CacheMaintenance.fileSizeOf。
    final fileSize = await CacheMaintenance.fileSizeOf(file);
    // P0-3 对应 v2：发送前预计算 SHA-256（上传 422 重试依赖，避免重复读盘）
    String? fileSha256;
    try {
      fileSha256 = await lsSha256OfFile(filePath);
    } catch (e) {
      // E1：SHA预计算日志收敛至 chat_debug_logs.shaFailLog。
      debugPrint(shaFailLog(e));
    }

    // 如果是图片，先生成缩略图（不阻塞发送，失败降级）
    if (isImage) {
      thumbPath = await _generateThumbnail(filePath, fileName);
    }

    // 端到端握手 ID（v2 不再使用，仅为兼容消息模型的非空字段）
    final transferId = _ids.newTransferId();

    if (isRetry) {
      // 重发：更新已有消息为 pending，不创建新消息
      // E1：文案抽至 send_waiting_texts.buildSendWaitingContent。
      // E1：!收敛至 send_naming.requireExistingId。
      final idx = findFirstIndexById(chatData, (m) => m.id, requireExistingId(existingMsg?.id));
      if (hasFoundIndex(idx) /* E1：命中委托 */ && mounted) {
        setState(() {
          // E1：断言收敛至 send_naming.requireExisting。
          chatData = replaceAt(chatData, idx, requireExisting(existingMsg).copyWith(
            content: waitingContentOverride ??
                buildSendWaitingContent(
                  errLabel: errLabel,
                  displayName: displayName,
                ),
            fileName: displayName,
            fileSize: formatFileSize(fileSize),
            filePath: filePath,
            // E1：分支收敛至 send_naming.resolveRecvImagePath。
            imagePath: resolveRecvImagePath(isImage: isImage, savedPath: filePath),
            thumbnailPath: thumbPath,
            progress: 0.0,
            transferState: TransferState.pending,
            transferId: transferId,
            isFolder: isFolder,
          ));
        });
        // E1：断言收敛至 send_naming.requireExisting。
        _cacheService.updateMessage(widget.id, requireExisting(existingMsg).id, chatData[idx]);
        _scrollToBottom();
      } else {
        return null;
      }
    } else {
      // 首次发送：创建 pending 消息
      // E1：文案抽至 send_waiting_texts.buildSendWaitingContent，
      // 构造抽至 message_factory。
      final pendingMsg = buildOutgoingFile(
        msgId: msgId,
        content: buildSendWaitingContent(
          errLabel: errLabel,
          displayName: displayName,
        ),
        isImage: isImage,
        displayName: displayName,
        fileSizeText: formatFileSize(fileSize),
        filePath: filePath,
        thumbPath: thumbPath,
        transferId: transferId,
        sessionId: null,
        isFolder: isFolder,
        now: now() /* E1：时钟收敛至 app_clock.now */,
      );
      if (mounted) {
        setState(() {
          chatData = appendMessage(chatData, pendingMsg);
        });
        _cacheService.appendMessage(widget.id, pendingMsg);
        _scrollToBottom();
      }
    }

    return _LsSendItem(
      msgId: msgId,
      filePath: filePath,
      fileName: fileName,
      fileSize: fileSize,
      sha256: fileSha256,
      isImage: isImage,
      isFolder: isFolder,
      isVoice: isVoice,
      durationMs: durationMs,
      waveformData: waveformData,
      errLabel: errLabel,
      displayName: displayName,
    );
  }

  /// v2 发送核心：把若干已就绪条目合并为一个协议会话发送。
  /// - 语音/文件夹先经 UDP 8888 发送 fileMeta 旁路元数据（v2 载荷无扩展字段）；
  /// - prepare-upload 挂起等接收方决策（无固定超时）；401 时弹 PIN 重试一次；
  /// - 接受后逐文件 uploadFile（进度节流回写气泡）；任一气泡取消 = 整会话取消；
  /// - 单文件失败仅标记该气泡，不阻塞其余文件。
  Future<void> _sendViaLs(List<_LsSendItem> items) async {
    if (items.isEmpty) return;
    // 本端设备信息：对端用它展示发送者（端口 = 本端 v2 HTTPS 服务端口）
    final info = LsDeviceDto(
      alias: widget.myDeviceName,
      fingerprint: TlsIdentityService.instance.fingerprint,
      port: widget.lsServer.boundPort,
      deviceType: deviceTypeLabel(isMobile: PlatformMobileExtension.isMobile),
    );

    // 语音/文件夹先发元数据旁路，接收端在 prepare-upload 到达前取得展示信息
    for (final it in items) {
      if (it.isVoice || it.isFolder) {
        widget.msgService.sendFileMeta(
          targetIp: _targetIp,
          fileName: it.fileName,
          fileSize: it.fileSize,
          isFolder: it.isFolder,
          isVoice: it.isVoice,
          durationMs: it.durationMs,
          waveformData: it.waveformData,
        );
      }
    }

    // 一个取消令牌管整批会话：任一气泡点取消 = 会话级取消
    final token = LsCancelToken();
    for (final it in items) {
      _lsCancelByMsgId[it.msgId] = token;
    }

    final files = <String, LsFileDto>{
      for (final it in items)
        it.msgId: LsFileDto.fromPath(
          id: it.msgId,
          filePath: it.filePath,
          size: it.fileSize,
          fileName: it.fileName,
          sha256: it.sha256,
        ),
    };

    // PIN 最多重试 1 次（对端 401 时弹框输入后整会话重试）
    // E1：轮数抽至 transfer_limits.shouldRetryPinAttempt。
    LsPrepareUploadResponse? prepared;
    String? pin;
    for (var attempt = 0; shouldRetryPinAttempt(attempt: attempt); attempt++) {
      try {
        debugPrint('[ChatPage] 发送目标: $_targetIp:${widget.peerTcpPort} '
            'fp=${_peerFingerprint ?? '空'}');
        prepared = await LsClient.instance.prepareUpload(
          ip: _targetIp,
          port: widget.peerTcpPort,
          info: info,
          files: files,
          pin: pin,
          // 钉扎对端证书指纹（发现层获得），mTLS 携带本端证书
          expectedFingerprint: _peerFingerprint,
          cancel: token,
        );
        break;
      } on LsSendError catch (e) {
        if (token.isCancelled) {
          // 用户取消（气泡按钮/dispose）：整批标“已取消”
          await _markLsCancelled(items);
          return;
        }
        debugPrint('[ChatPage] prepare-upload 失败: kind=${e.kind.name} '
            'status=${e.statusCode} ${e.userText}');
        if (e.kind == LsErrorKind.pinRequired && attempt == 0 && mounted) {
          // 对端开启接收 PIN：弹框输入后重试一次
          final input = await _promptForPin(
            // E1：分支抽至 send_waiting_texts.resolvePinHint。
            resolvePinHint(null),
          );
          // E1：判空抽至 text_edit.isNullOrEmptyInput。
          if (isNullOrEmptyInput(input)) {
            // 用户取消 PIN 输入：视为主动取消
            await _markLsCancelled(items);
            return;
          }
          pin = input;
          continue;
        }
        await _markLsFailed(items, e.userText);
        return;
      }
    }
    final session = prepared;
    if (session == null) return; // 循环内已处理失败/取消

    // 会话确立：记录映射（取消按钮回查 / 对端 /cancel 转发定位用）
    for (final it in items) {
      _lsSessionByMsgId[it.msgId] = session.sessionId;
    }

    // 逐文件上传；单文件失败仅标记该气泡
    for (final it in items) {
      final fileToken = session.files[it.msgId];
      // E1：判空抽至 text_edit（!收敛至 requireNonNullHint 保提升）。
      if (isNullOrEmptyInput(fileToken)) {
        await _markLsFailed([it], '对方拒绝了本次传输');
        continue;
      }
      try {
        await LsClient.instance.uploadFile(
          ip: _targetIp,
          port: widget.peerTcpPort,
          sessionId: session.sessionId,
          fileId: it.msgId,
          token: requireNonNullHint(fileToken),
          filePath: it.filePath,
          fileSize: it.fileSize,
          expectedFingerprint: _peerFingerprint,
          cancel: token,
          onProgress: (sent, total) => _onLsSendProgress(it, sent, total),
        );
        await _markLsCompleted(it);
      } on LsSendError catch (e) {
        if (token.isCancelled) {
          // 会话级取消：整批标记后退出（后续文件不再发送）
          await _markLsCancelled(items);
          return;
        }
        await _markLsFailed([it], e.userText);
      } catch (e) {
        // E1：发送失败日志收敛至 chat_debug_logs.sendFailLog。
        debugPrint(sendFailLog(e));
        await _markLsFailed([it], TransferTexts.truncateError(e));
      }
    }
  }

  /// v2 发送进度回写（~80ms 节流）：气泡转传输中并刷新百分比。
  void _onLsSendProgress(_LsSendItem it, int sent, int total) {
    final idx = findFirstIndexById(chatData, (m) => m.id, it.msgId);
    if (isMissingIndex(idx)) return; // E1：未命中委托
    if (shouldGuardTerminal(chatData[idx].transferState)) return;
    // E1：节流抽至 text_retry_policy.shouldThrottleProgress。
    final nowTick = nowMs() /* E1：时钟收敛至 app_clock.nowMs */;
    final last = lastProgressTickOrZero(_lastProgressTick, it.msgId);
    if (shouldThrottleProgress(lastTickMs: last, nowMs: nowTick)) return;
    _lastProgressTick[it.msgId] = nowTick;
    if (!mounted) return;
    final progress = total > 0 ? sent / total : 0.0;
    setState(() {
      final i = findFirstIndexById(chatData, (m) => m.id, it.msgId);
      if (isMissingIndex(i)) return;
      if (shouldGuardTerminal(chatData[i].transferState)) return;
      // 语音气泡保持 🎙️ 文案，仅刷新进度条
      chatData = replaceAt(chatData, i, chatData[i].copyWith(
        progress: progress,
        transferState: TransferState.transferring,
        content: isAudioMessageType(chatData[i].type.name)
            ? chatData[i].content
            : '${it.isFolder ? '📁' : '📤'} 发送中: ${it.displayName} (${(progress * 100).toStringAsFixed(0)}%)',
      ));
    });
  }

  /// v2 单文件发送完成：气泡转已完成并写缓存（语音保持 🎙️ 文案）。
  Future<void> _markLsCompleted(_LsSendItem it) async {
    _lastProgressTick.remove(it.msgId);
    final idx = findFirstIndexById(chatData, (m) => m.id, it.msgId);
    if (isMissingIndex(idx)) return; // E1：未命中委托
    final old = chatData[idx];
    if (shouldGuardTerminal(old.transferState)) return;
    final completed = isAudioMessageType(old.type.name)
        ? TransferTexts.markCompletedKeepContent(old)
        : old.copyWith(
            content:
                '${it.isFolder ? '📁' : '📤'} 发送成功: ${it.displayName}',
            transferState: TransferState.completed,
            progress: 1.0,
          );
    if (mounted) {
      setState(() {
        final i = findFirstIndexById(chatData, (m) => m.id, it.msgId);
        if (hasFoundIndex(i)) chatData = replaceAt(chatData, i, completed);
      });
    }
    await _cacheService.updateMessage(widget.id, it.msgId, completed);
  }

  /// v2 会话级取消（用户取消 / PIN 取消 / 对端断开）：整批标“已取消”。
  Future<void> _markLsCancelled(List<_LsSendItem> items) async {
    final updated = <ChatMessage>[];
    if (mounted) {
      setState(() {
        for (final it in items) {
          final idx = findFirstIndexById(chatData, (m) => m.id, it.msgId);
          if (isMissingIndex(idx)) continue;
          final old = chatData[idx];
          // 终态保护：已到完成/失败的结果不被取消覆盖
          if (shouldGuardTerminal(old.transferState)) continue;
          final cancelled = TransferTexts.markCancelLocal(
            old,
            localCancelContent(
              isAudio: isAudioMessageType(old.type.name),
              isMe: old.isMe,
              fileName: fileNameOrEmpty(old.fileName),
            ),
          );
          chatData = replaceAt(chatData, idx, cancelled);
          updated.add(cancelled);
        }
      });
    }
    for (final it in items) {
      _lastProgressTick.remove(it.msgId);
      _lsCancelByMsgId.remove(it.msgId);
      _lsSessionByMsgId.remove(it.msgId);
    }
    for (final m in updated) {
      await _cacheService.updateMessage(widget.id, m.id, m);
    }
  }

  /// v2 发送失败：条目标失败气泡（语音保持 🎙️ + 红色感叹号样式）。
  Future<void> _markLsFailed(List<_LsSendItem> items, String errorText) async {
    final updated = <ChatMessage>[];
    if (mounted) {
      setState(() {
        for (final it in items) {
          final idx = findFirstIndexById(chatData, (m) => m.id, it.msgId);
          if (isMissingIndex(idx)) continue;
          final old = chatData[idx];
          // 终态保护：取消/完成先到时不覆盖
          if (shouldGuardTerminal(old.transferState)) continue;
          final ChatMessage failed;
          if (isAudioMessageType(old.type.name)) {
            // E1：恒定标签抽至 emoji_bubble_texts.audioLabel。
            // E1：失败变异收敛至 TransferTexts.markAudioLabel。
            failed = TransferTexts.markAudioLabel(old, audioLabel());
          } else {
            // E1：异常拼接抽至 send_waiting_texts.buildSendExceptionContent。
            // E1：失败变异收敛至 TransferTexts.markFailedWithContent。
            failed = TransferTexts.markFailedWithContent(
              old,
              buildSendExceptionContent(
                errLabel: it.errLabel,
                displayName: it.displayName,
                truncatedError: errorText,
              ),
            );
          }
          chatData = replaceAt(chatData, idx, failed);
          updated.add(failed);
        }
      });
    }
    for (final it in items) {
      _lastProgressTick.remove(it.msgId);
      _lsCancelByMsgId.remove(it.msgId);
      _lsSessionByMsgId.remove(it.msgId);
    }
    for (final m in updated) {
      await _cacheService.updateMessage(widget.id, m.id, m);
    }
  }

  void insertText(String text) {
    // E1：插入逻辑抽至 text_edit.applyTextInsert（纯函数可单测），此处仅薄委托。
    final TextEditingValue value = _textController.value;
    if (!value.selection.isValid) {
      final r = applyTextInsert(
        current: '',
        baseOffset: 0,
        extentOffset: 0,
        valid: false,
        insert: text,
      );
      _textController.value = TextEditingValue(
        text: r.text,
        selection: TextSelection.fromPosition(
          TextPosition(offset: r.caret),
        ),
      );
      return;
    }
    final r = applyTextInsert(
      current: value.text,
      baseOffset: value.selection.baseOffset,
      extentOffset: value.selection.extentOffset,
      valid: true,
      insert: text,
    );
    _textController.value = value.copyWith(
      text: r.text,
      // E1：copyWith留宿主（text_edit纯dart无flutter依赖，不收insertAt）。
      selection: value.selection.copyWith(
        baseOffset: r.caret,
        extentOffset: r.caret,
      ),
    );
  }

  /// 收到对方发来的拉黑状态同步包（方案2中的 best-effort 推送）。
  /// blocked=true：快速取消所有待确认定时器，标记 sending 消息为失败。
  /// blocked=false：对方解除拉黑，允许恢复发送。
  /// 即使这个包丢了，ACK blocked 标记也能保证最终一致。
  void _onBlockSyncReceived(ReceivedMessage msg) {
    // E1：标志抽至 text_inbound.parseBlockedFlag。
    final blocked = parseBlockedFlag(msg.payload);
    // E1：blockSync日志收敛至 chat_debug_logs.blockSyncLog。
    debugPrint(blockSyncLog(blocked));

    if (blocked) {
      _isBlockedByPeer = true;

      // 只处理自己发的、且当前处于 sending 状态的消息
      // 已完成(completed)和已失败(failed)的消息不受影响
      // E1：批量判定抽至 ack_decision.applyBlockSyncFailed（纯函数可单测）。
      final r = applyBlockSyncFailed(chatData);
      final blockedMsgIds = r.ids;
      final changed = r.changed;
      chatData = r.messages;

      // 只取消被标记为失败的消息的 ACK 定时器
      // 不取消其他消息的定时器（已完成消息的 ACK 可能还在路上）
      // E1：批量取消抽至 text_retry_policy.cancelAckTimersForIds。
      cancelAckTimersForIds(_pendingAcks, _retryCount, blockedMsgIds, (t) => t.cancel());

      // 逐条更新缓存，避免全量保存覆盖并发修改
      if (changed) {
        for (final m in chatData) {
          if (blockedMsgIds.contains(m.id)) {
            _cacheService.updateMessage(widget.id, m.id, m);
          }
        }
      }

      if (changed) {
        // E1：文案抽至 send_waiting_texts.blockedByPeerText。
        _showCenterToast(blockedByPeerText());
      }
      // 消息流回调可能发生在 build 阶段，使用 post-frame 安全刷新
      if (mounted && changed) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() {});
        });
      }
    } else {
      _isBlockedByPeer = false;
    }
  }

  /// 检查对方设备是否在线/已拉黑。
  /// P1-3：心跳 5s 内新鲜则跳过 ping，避免弱网下每次发送卡 2s+。
  Future<bool> _checkTargetOnline() async {
    // E1：门控决策抽至 online_check（纯函数可单测），IO 留此处。
    final gate = decideOnlineGate(
      blocked: _isBlocked || _isBlockedByPeer,
      knownOnline: widget.msgService.isDeviceOnline(widget.id),
      heartbeatAge: widget.msgService.heartbeatAge(widget.id),
      // E1：直调 transfer_limits.kFreshHeartbeatSec（去上帝类别名）。
      freshWindow: const Duration(seconds: kFreshHeartbeatSec),
    );
    switch (gate) {
      case OnlineGate.blocked:
        // E1：文案抽至 send_waiting_texts.blockedByPeerText/peerOfflineText。
        _showCenterToast(blockedByPeerText());
        return false;
      case OnlineGate.offlineKnown:
        _showCenterToast(peerOfflineText());
        return false;
      case OnlineGate.freshOk:
        return true;
      case OnlineGate.needPing:
        break;
    }
    // 心跳偏旧：用当前路由 IP ping（P0-7 后 widget.id 是身份键，不能当目标地址）
    // E1：抽至 transfer_limits.kPingTimeoutSec。
    final reachable = await widget.msgService.pingDevice(
      _targetIp,
      timeout: const Duration(seconds: kPingTimeoutSec),
    );
    if (!mapPingResult(reachable)) {
      // E1：文案抽至 send_waiting_texts.peerOfflineText。
      _showCenterToast(peerOfflineText());
      return false;
    }
    return true;
  }

  /// S2：对方要求 PIN 时弹输入框，取消返回 null。
  Future<String?> _promptForPin(String hint) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      // E1：标题/提示抽至 send_waiting_texts.pinDialogTitle/pinDialogHint。
      builder: (ctx) => AlertDialog(
        title: Text(pinDialogTitle()),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(hint, style: TextStyle(fontSize: pinHintFontSize(), color: Colors.grey)), // E1：字号委托至 media_layout
            SizedBox(height: pinFieldGapH()), // E1：间距委托至 media_layout
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              maxLength: 8,
              obscureText: true,
              decoration: InputDecoration(
                // E1：抽至 send_waiting_texts.pinDialogHint。
                hintText: pinDialogHint(),
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            // E1：抽至 emoji_bubble_texts.cancelText。
            child: Text(cancelText()),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            // E1：抽至 emoji_bubble_texts.pinRetryText。
            child: Text(pinRetryText()),
          ),
        ],
      ),
    );
  }

  /// 屏幕居中显示一个圆角气泡提示，3 秒后自动消失
  /// E1：实现复用 toast_utils.showCenterToast，仅保留 mounted 门控（可单测时序在 transfer_limits.kToastSec）。
  void _showCenterToast(String message) {
    if (!mounted) return;
    showCenterToast(context, message);
  }

  // E1：缓存裁剪已收敛至 image_existence_cache/bounded_cache，薄委托替代旧 _trimCacheIfNeeded。

  // ========== 黑名单状态持久化 ==========

  /// 获取黑名单存储文件路径
  Future<String> _getBlockedFilePath() =>
      AppConfigStore.pathFor(AppConfigStore.blockedFile);

  /// 加载当前设备的黑名单状态
  /// E1：集合解析抽至 blocked_list.parseBlockedList/isDeviceBlocked。
  Future<void> _loadBlockedState() async {
    try {
      final filePath = await _getBlockedFilePath();
      final file = File(filePath);
      if (!await file.exists()) return;
      final content = await file.readAsString();
      final blockedList = parseBlockedList(content);
      _isBlocked = isDeviceBlocked(blockedList, widget.id);
    } catch (e) {
      // E1：黑名单加载日志收敛至 chat_debug_logs.loadBlockFailLog。
      debugPrint(loadBlockFailLog(e));
    }
  }

  /// 保存黑名单状态
  /// E1：集合合并抽至 blocked_list.mergeBlockedList。
  Future<void> _saveBlockedState() async {
    try {
      final filePath = await _getBlockedFilePath();
      var blockedList = <String>[];
      final file = File(filePath);
      if (await file.exists()) {
        final content = await file.readAsString();
        blockedList = parseBlockedList(content);
      }
      blockedList = mergeBlockedList(
        current: blockedList,
        deviceId: widget.id,
        blocked: _isBlocked,
      );
      await AppConfigStore.writeAtomic(
        AppConfigStore.blockedFile,
        jsonEncode(blockedList),
      );
    } catch (e) {
      // E1：黑名单保存日志收敛至 chat_debug_logs.saveBlockFailLog。
      debugPrint(saveBlockFailLog(e));
    }
  }

  // ===== 通用动作气泡（复制 / 文件位置等） =====

  /// 统一动作气泡：长按消息时在下方弹出，箭头向上指向消息。
  /// [actions] 每个元素包含 label 和 onTap。
  void _showActionBubble(
    List<({String label, VoidCallback onTap})> actions,
    Rect targetBounds,
  ) {
    _hideActionBubble();

    final overlay = Overlay.of(context);
    final screenSize = MediaQuery.of(context).size;
    final safeTop = MediaQuery.of(context).padding.top;
    final safeBottom = MediaQuery.of(context).padding.bottom;
    late final OverlayEntry entry;

    // E1：几何抽至 action_bubble_layout.kActionBubble*。
    const double bubbleH = kActionBubbleH;
    const double arrowH = kActionBubbleArrowH;
    const double arrowW = kActionBubbleArrowW;
    const double radius = kActionBubbleRadius;
    const Color bubbleColor = Color(0xCC2C2C2E);
    final double totalHeight = bubbleH + arrowH;

    // 根据 action 数量和文字长度计算气泡宽度
    // E1：抽至 action_bubble_layout.computeActionBubbleLayout。
    final layout = computeActionBubbleLayout(
      labels: [for (final a in actions) a.label],
      targetLeft: targetBounds.left,
      targetTop: targetBounds.top,
      targetRight: targetBounds.right,
      targetBottom: targetBounds.bottom,
      targetCenterX: targetBounds.center.dx,
      screenWidth: screenSize.width,
      screenHeight: screenSize.height,
      safeTop: safeTop,
      safeBottom: safeBottom,
    );
    final double popupWidth = layout.popupWidth;
    final double left = layout.left;
    final double arrowX = layout.arrowX;
    final double top = layout.top;
    final bool arrowOnTop = layout.arrowOnTop;

    entry = OverlayEntry(
      builder: (_) => Positioned(
        left: left,
        // E1：重复 clamp 收敛至 clampBubbleTop（行为不变）。
        top: clampBubbleTop(
          top: top,
          safeTop: safeTop,
          screenH: screenSize.height,
          totalH: totalHeight,
          safeBottom: safeBottom,
        ),
        child: Material(
          color: Colors.transparent,
          child: SizedBox(
            width: popupWidth,
            height: totalHeight,
            child: CustomPaint(
              painter: _ActionBubblePainter(
                arrowX: arrowX,
                arrowOnTop: arrowOnTop,
                color: bubbleColor,
                radius: radius,
                arrowW: arrowW,
                arrowH: arrowH,
              ),
              child: Padding(
                padding: EdgeInsets.only(
                  // E1：几何收敛至 action_bubble_layout.bubbleRectTop/bubbleEdgeBottom。
                  top: bubbleRectTop(arrowOnTop: arrowOnTop, arrowH: arrowH),
                  bottom: bubbleEdgeBottom(arrowOnTop: arrowOnTop, arrowH: arrowH),
                ),
                child: Row(
                  children: [
                    for (int i = 0; i < actions.length; i++) ...[
                      // E1：分隔线门控抽至 shouldShowActionDivider。
                      if (shouldShowActionDivider(i))
                        Container(
                          width: 0.5,
                          height: 18,
                          color: Colors.white24,
                        ),
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            _hideActionBubble();
                            actions[i].onTap();
                          },
                          child: Center(
                            child: Text(
                              actions[i].label,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    _actionBubbleEntry = entry;
    overlay.insert(entry);

    // E1：抽至 transfer_limits.kActionBubbleSec。
    Future.delayed(bubbleHide() /* E1：延时收敛至 delay_policy */, () {
      if (_actionBubbleEntry == entry) _hideActionBubble();
    });
  }

  /// 根据 widget 的 BuildContext 获取全局 bounds 后显示动作气泡。
  void _showActionBubbleFromContext(
    BuildContext ctx,
    List<({String label, VoidCallback onTap})> actions,
  ) {
    final RenderBox? box = ctx.findRenderObject() as RenderBox?;
    // E1：as cast留宿主（需BuildContext/findRenderObject）；有效性已委托isInvalidRenderBox/hasValidBox。
    // E1：有效性门控抽至 isInvalidRenderBox（语义不变）。
    // E1：正向判定委托至 text_edit.hasValidBox。
    // E1：?.链收敛至 pick_classify.pickBoxHasSizeOrFalse。
    if (!hasValidBox(isNull: box == null, hasSize: pickBoxHasSizeOrFalse(box?.hasSize))) {
      return;
    }
    // E1：box!留宿主（判空后断言，需RenderBox实例）。
    final b = box!;
    final Offset topLeft = b.localToGlobal(Offset.zero);
    _showActionBubble(actions, topLeft & b.size);
  }

  void _hideActionBubble() {
    _actionBubbleEntry?.remove();
    _actionBubbleEntry = null;
  }

  /// 打开文件所在位置：桌面端用系统文件管理器，移动端调起分享面板。
  Future<void> _openFileLocation(String filePath) async {
    try {
      final dir = Directory(filePath);
      final bool isDirectory = await dir.exists();
      // E1：命令分支抽至 file_location_command.buildOpenLocationCommand。
      final cmd = buildOpenLocationCommand(
        isWindows: Platform.isWindows,
        isMacOS: Platform.isMacOS,
        isLinux: Platform.isLinux,
        isDirectory: isDirectory,
        filePath: filePath,
        dirPath: pth.dirname(filePath),
      );
      final c = cmd;
      if (isNotNull(c)) { // E1：非空判定委托
        await Process.start(c!.exe, c.args);
      } else {
        // Android / iOS：调起系统分享面板
        // E1/新库：path.basename 跨平台取文件名。
        final xFile = XFile(filePath);
        await Share.shareXFiles([
          xFile,
        ], subject: pth.basename(filePath));
      }
    } catch (e) {
      // E1：打开位置日志收敛至 chat_debug_logs.openLocFailLog。
      debugPrint(openLocFailLog(e));
      // E1：文案抽至 send_waiting_texts.openLocationFailedText。
      _showCenterToast(openLocationFailedText());
    }
  }

  /// U2：把已接收文件交给系统分享面板（发给其他 App）。失败只提示，不抛。
  /// E1/新库：path.basename 跨平台取文件名。
  Future<void> _shareFile(String filePath) async {
    try {
      await Share.shareXFiles([
        XFile(filePath),
      ], subject: pth.basename(filePath));
    } catch (e) {
      // E1：分享失败日志收敛至 chat_debug_logs.shareFailLog。
      debugPrint(shareFailLog(e));
      // E1：文案抽至 send_waiting_texts.shareFailedText。
      _showCenterToast(shareFailedText());
    }
  }

  /// 构造文件消息的动作列表（文件位置 + 分享）。
  /// E1：标签抽至 message_actions（纯函数可单测），onTap 绑定留此处。
  List<({String label, VoidCallback onTap})> _buildFileActions(
    ChatMessage msg,
  ) {
    final actions = <({String label, VoidCallback onTap})>[];
    final filePath = msg.filePath;
    for (final label in fileActionLabels(filePath)) {
      // E1：比较走 message_actions 常量，避免魔法字符串。
      if (isFileLocationAction(label, kFileLocationAction, filePath)) { // E1：动作门控委托
        actions.add((label: label, onTap: () => _openFileLocation(filePath!))); // E1：判空后断言
      } else if (isFileLocationAction(label, kShareAction, filePath)) { // E1：动作门控委托
        actions.add((label: label, onTap: () => _shareFile(filePath!))); // E1：判空后断言
      }
    }
    return actions;
  }

  /// 构造纯文本消息的动作列表（复制）。
  /// E1：标签抽至 message_actions，剪贴板绑定留此处。
  List<({String label, VoidCallback onTap})> _buildCopyAction(ChatMessage msg) {
    return [
      for (final label in copyActionLabels())
        (
          label: label,
          onTap: () {
            Clipboard.setData(ClipboardData(text: msg.content));
            // E1：文案抽至 send_waiting_texts.copyDoneText。
            _showCenterToast(copyDoneText());
          },
        ),
    ];
  }

  /// 统一发送入口：在线检查 + 按类型分发到具体发送逻辑。
  /// 今后新增消息类型只需在此处加一个 case 分支即可。
  Future<void> _trySend({
    required SendActionType type,
    String? text,
    String? msgId,
    String? filePath,
    String? fileName,
    bool isImage = false,
    bool isFolder = false,
    RecordResult? recordResult,
    ChatMessage? retryMsg,
  }) async {
    if (!await _checkTargetOnline()) return;

    switch (type) {
      case SendActionType.text:
        _sendTextWithRetry(msgId!, text!);
      case SendActionType.file:
      case SendActionType.image:
        await _sendFileFromPath(
          filePath!,
          fileName!,
          // E1：图片判定抽至 send_dispatch.resolveSendIsImage。
          isImage: resolveSendIsImage(
            type: type.name,
            isImageFlag: isImage,
          ),
          isFolder: isFolder,
          existingMsg: retryMsg,
        );
      case SendActionType.audio:
        await _sendAudioMessage(recordResult!, waveformData: text);
      case SendActionType.audioRetry:
        await _retrySendAudio(retryMsg!);
    }
  }

  Future<void> _handleSubmittedData(String text) async {
    // E1：抽至 bubble_meta.isBlankText/send_naming.newTextMsgId。
    if (isBlankText(text)) return;
    _textController.clear();

    // 必须先检查在线状态，通过后才插入消息并发送
    if (!await _checkTargetOnline()) return;

    // E1：发送文字日志收敛至 chat_debug_logs.sendText*。
    debugPrint(sendTextStartLog());
    debugPrint(sendTextTargetLog(widget.id));
    debugPrint(sendTextContentLog(text));
    debugPrint(
      sendTextStatusLog(
        widget.msgService.isRunning,
        widget.msgService.localIP,
      ),
    );

    final msgId = newTextMsgId(nowMs() /* E1：时钟收敛至 app_clock.nowMs */);
    // E1：构造抽至 message_factory.buildOutgoingText。
    final newMsg = buildOutgoingText(
      msgId: msgId,
      text: text,
      now: now() /* E1：时钟收敛至 app_clock.now */,
    );

    setState(() {
      chatData = appendMessage(chatData, newMsg);
    });
    _cacheService.appendMessage(widget.id, newMsg);
    _scrollToBottom();

    // 在线检查已通过，入队发送（带指数退避重传）
    _sendTextWithRetry(msgId, text);
  }

  Duration _ackTimeoutFor(int retry) =>
      // E1：抽至 text_retry_policy.ackTimeoutFor，直调 kAckBaseTimeoutMs。
      ackTimeoutFor(retry, baseMs: kAckBaseTimeoutMs);

  bool _isRecvDuplicate(String msgId) {
    // E1：抽至 text_retry_policy.isRecvDuplicate/send_naming.buildRecvMsgId。
    final exists = containsId(chatData, (m) => m.id, buildRecvMsgId(msgId));
    return isRecvDuplicate(
      recent: _recentRecvMsgIds,
      msgId: msgId,
      now: now() /* E1：时钟收敛至 app_clock.now */,
      // E1：直调 kRecvDedupTtlSec。
      ttl: const Duration(seconds: kRecvDedupTtlSec),
      existsInChat: exists,
    );
  }

  /// 发送文字消息（P1-3：入队 + 指数退避 + msgId 去重）
  void _sendTextWithRetry(String msgId, String text, {int retry = 0}) {
    // E1：抽至 text_retry_policy.shouldSkipDuplicateSend。
    if (shouldSkipDuplicateSend(
      retry: retry,
      alreadyPending: _pendingAcks.containsKey(msgId),
    )) {
      // E1：文字去重日志收敛至 chat_debug_logs.sendTextDedupLog。
      debugPrint(sendTextDedupLog(msgId));
      return;
    }
    _textQueue.add(QueuedText(msgId, text, retry));
    _drainTextQueue();
  }

  Future<void> _drainTextQueue() async {
    if (_textQueue.running) return;
    _textQueue.running = true;
    // E1：队列门控收敛至 bubble_meta.hasQueuedText。
    while (hasQueuedText(_textQueue.items.isNotEmpty)) {
      final item = _textQueue.takeNext()!;
      await _emitQueuedText(item);
      if (_textQueue.needsGap) {
        // E1：直调 kTextSendGapMs。
        await gapDelay(ackGap() /* E1：延时收敛至 delay_policy */);
      }
    }
    _textQueue.running = false;
  }

  Future<void> _emitQueuedText(QueuedText item) async {
    final msgId = item.msgId;
    final text = item.text;
    final retry = item.retry;

    await widget.msgService.sendTextMessage(
      targetIp: _targetIp,
      content: text,
      senderName: widget.myDeviceName,
      msgId: msgId,
      // S5：有对端指纹时加密发送；旧端无指纹走明文兼容。
      peerFingerprint: _peerFingerprint,
    );

    _pendingAcks[msgId]?.cancel();
    _pendingAcks[msgId] = Timer(_ackTimeoutFor(retry), () {
      // E1：抽至 text_retry_policy.shouldAbortTextRetry。
      if (shouldAbortTextRetry(
        blockedLocal: _isBlocked,
        blockedByPeer: _isBlockedByPeer,
      )) {
        // E1：取消抽至 text_retry_policy.cancelAckTimer。
        cancelAckTimer(_pendingAcks, _retryCount, msgId, (t) => t.cancel());
        // E1：放弃重试日志收敛至 chat_debug_logs.abortRetryLog。
        debugPrint(abortRetryLog(msgId, _isBlocked));
        if (mounted) {
          setState(() {
            final index = findFirstIndexById(chatData, (m) => m.id, msgId);
            // E1：sending 门控抽至 ack_decision.shouldMarkBlockedFailed，
            // 文案抽至 TransferTexts.textSendFailedContent。
            if (hasFoundIndex(index) /* E1：命中委托 */ &&
                shouldMarkBlockedFailed(chatData[index].transferState)) {
              // E1：变异抽至 TransferTexts.markTextFailed。
              chatData = replaceAt(chatData, index, TransferTexts.markTextFailed(
                chatData[index],
                text,
              ));
            }
          });
          // E1：文案抽至 send_waiting_texts.blockedByPeerText。
          _showCenterToast(blockedByPeerText());
        }
        return;
      }
      // E1：序号抽至 text_retry_policy.nextTextRetry。
      final next = nextTextRetry(retry);
      // E1：抽至 text_retry_policy.nextTextRetry/shouldGiveUpText，直调 kMaxTextRetries。
      if (!shouldGiveUpText(next, maxRetries: kMaxTextRetries)) {
        _retryCount[msgId] = next;
        // E1：ACK重试日志收敛至 chat_debug_logs.retryAckLog。
        debugPrint(retryAckLog(msgId, next, _ackTimeoutFor(next).inMilliseconds));
        _sendTextWithRetry(msgId, text, retry: next);
      } else {
        // E1：取消抽至 text_retry_policy.cancelAckTimer。
        cancelAckTimer(_pendingAcks, _retryCount, msgId, (t) => t.cancel());
        // E1：文字失败日志收敛至 chat_debug_logs.sendTextFailLog。
        debugPrint(sendTextFailLog(msgId, kMaxTextRetries));
        // P1-T7：最终失败入离线队列，对端上线（_onlineDeviceIds 新增）时重推。
        // E1：回调空安全调用留宿主（?.call透传，宿主直接调用）。
        widget.onTextSendFailed?.call(msgId, text);
        if (mounted) {
          setState(() {
            final index = findFirstIndexById(chatData, (m) => m.id, msgId);
            if (hasFoundIndex(index)) /* E1：命中委托 */ {
              // E1：变异抽至 TransferTexts.markTextFailed。
              chatData = replaceAt(chatData, index, TransferTexts.markTextFailed(
                chatData[index],
                text,
              ));
            }
          });
        }
      }
    });
  }

  void onTapMore() {
    _panelSwitching = true;
    // E1：状态机抽至 send_dispatch.nextMorePanel。
    final next = nextMorePanel(
      isMore: _isMore,
      hasFocus: _focusNode.hasFocus,
    );
    setState(() {
      _isVoice = false;
      _isMore = next.isMore;
      _emojiState = next.emojiState;
      if (next.needFocus) {
        _focusNode.requestFocus();
      } else if (next.needUnfocus) {
        _focusNode.unfocus();
      }
    });
    // E1：防抖抽至 send_dispatch.kPanelSwitchMs。
    Future.delayed(panelDebounce() /* E1：延时收敛至 delay_policy */, () {
      _panelSwitching = false;
    });
  }

  void onTapEmoji() {
    _panelSwitching = true;
    // E1：状态机抽至 send_dispatch.nextEmojiPanel。
    final next = nextEmojiPanel(
      emojiState: _emojiState,
      hasFocus: _focusNode.hasFocus,
    );
    setState(() {
      _isVoice = false;
      _isMore = next.isMore;
      _emojiState = next.emojiState;
      if (next.needFocus) {
        _focusNode.requestFocus();
      } else if (next.needUnfocus) {
        _focusNode.unfocus();
      }
    });
    Future.delayed(panelDebounce() /* E1：延时收敛至 delay_policy */, () {
      _panelSwitching = false;
    });
  }

  /// E3：滚到顶部时往前补一页历史。用当前长度作偏移，prepend 后保持视口不动。
  Future<void> _loadOlderHistory() async {
    if (_loadingOlder || !_historyHasMore) return;
    _loadingOlder = true;
    try {
      final all = await _cacheService.loadMessages(widget.id);
      // E1：过滤抽至 history_paging.withoutInitMessages。
      final older = withoutInitMessages(all, (m) => m.id);
      // E1：无更早历史收敛至 history_paging.noOlderHistory。
      if (noOlderHistory(older: older.length, loaded: chatData.length)) {
        if (mounted) setState(() => _historyHasMore = false);
        return;
      }
      // E1：上一页切片抽至 history_paging（纯函数可单测）。
      final sliced = olderHistoryPage(
        older: older,
        loadedCount: chatData.length,
        pageSize: kHistoryPageSize,
      );
      final from = sliced.from;
      final page = sliced.page;
      // E1：中止门控抽至 history_paging.shouldAbortHistoryLoad。
      if (shouldAbortHistoryLoad(mounted: mounted, empty: page.isEmpty)) return;
      // E1：滚动基准抽至 scrollBaseExtent。
      final before = scrollBaseExtent(
        hasClients: _scrollController.hasClients,
        maxExtent: _scrollController.hasClients
            ? _scrollController.position.maxScrollExtent
            : 0.0,
      );
      setState(() {
        chatData = prependHistory(chatData, page);
        _historyHasMore = historyHasMore(from);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        final grew = _scrollController.position.maxScrollExtent - before;
        // E1：视口保持抽至 keepViewportOffset。
        _scrollController.jumpTo(
          keepViewportOffset(offset: _scrollController.offset, grew: grew),
        );
      });
    } finally {
      _loadingOlder = false;
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          // E1：时长抽至 send_dispatch.kScrollAnimMs。
          duration: scrollAnim() /* E1：延时收敛至 delay_policy */,
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeaveDuringTransfer() && context.mounted) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: const Color(0xFFEDF0F3),
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: const Color(0xFFF3F3F3),
        elevation: 0.5,
        iconTheme: const IconThemeData(color: Colors.black87),
        titleTextStyle: const TextStyle(
          color: Colors.black87,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.more_horiz),
            onPressed: () async {
              final result =
                  await Navigator.push<
                    ({
                      bool autoReceive,
                      bool isBlocked,
                      bool chatHistoryCleared,
                    })
                  >(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ChatInfoPage(
                        id: widget.id,
                        name: widget.title,
                        cacheService: _cacheService,
                        initialAutoReceive: _autoReceive,
                        initialIsBlocked: _isBlocked,
                      ),
                    ),
                  );
              if (result != null && mounted) {
                // 如果清除了聊天记录，立即刷新页面
                if (result.chatHistoryCleared) {
                  setState(() {
                    chatData = [];
                  });
                }
                setState(() {
                  _autoReceive = result.autoReceive;
                  _isBlocked = result.isBlocked;
                });
                // 持久化黑名单状态
                _saveBlockedState();
                // 通知 ChatListPage 持久化自动接收状态
                // E1：回调空安全调用留宿主（?.call透传，宿主直接调用）。
                widget.onAutoReceiveChanged?.call(result.autoReceive);
                // 方案2：blocked=true 不发送 blockSync（由消息 ACK 机制可靠同步）
                // blocked=false 仍需发送，因为被拉黑方可能已停止发送消息，
                // 需要主动推送通知对方可以恢复发送
                if (!result.isBlocked) {
                  widget.msgService.sendBlockSync(
                    targetIp: _targetIp,
                    blocked: false,
                  );
                  // E1：解封日志收敛至 chat_debug_logs.unblockSyncLog。
                  debugPrint(unblockSyncLog());
                }
              }
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              // 面板高度基于 Scaffold body 实际可用高度，避免键盘/面板切换时溢出
              // E1：占比抽至 send_dispatch.kPanelHeightRatio。
              // E1：高度折算抽至 send_dispatch.panelHeight。
              final panelH = panelHeight(constraints.maxHeight);

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Divider(
                    height: 0.5,
                    thickness: 0.5,
                    color: Colors.grey.shade300,
                  ),
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: () {
                        _focusNode.unfocus();
                        _hideActionBubble();
                      },
                      child: NotificationListener<ScrollNotification>(
                        onNotification: (n) {
                          // E1：阈值/门控抽至 send_dispatch.shouldLoadOlder。
                          if (n is ScrollUpdateNotification &&
                              shouldLoadOlder(
                                pixels: n.metrics.pixels,
                                hasMore: _historyHasMore,
                              )) {
                            _loadOlderHistory();
                          }
                          return false;
                        },
                        child: ListView.builder(
                        controller: _scrollController,
                        key: const PageStorageKey('chatListView'),
                        itemCount: chatData.length,
                        padding: const EdgeInsets.all(15.0),
                        itemBuilder: (context, index) {
                          final msg = chatData[index];
                          return _buildChatBubble(msg, key: ValueKey(msg.id));
                        },
                        ),
                      ),
                    ),
                  ),
                  _buildInputBar(),
                  Visibility(
                    visible: _emojiState,
                    maintainState: true,
                    child: Container(
                      height: panelH,
                      color: const Color(0xFFF6F6F6),
                      child: _buildEmojiWidget(),
                    ),
                  ),
                  Visibility(
                    visible: _isMore,
                    maintainState: true,
                    child: Container(
                      height: panelH,
                      color: const Color(0xFFF6F6F6),
                      child: ChatMorePage(
                        id: widget.id,
                        onFileSelected: _openFilePicker,
                        onPickImage: _pickImageFromGallery,
                        onTakePhoto: _takePhoto,
                        onFolderSelected: _openFolderPicker,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          // 录音遮罩层
          if (_showRecordMask) _buildRecordMask(),
        ],
      ),
      ),
    );
  }

  // ========== 聊天气泡（支持文字/图片/文件/音频/进度条） ==========
  Widget _buildChatBubble(ChatMessage msg, {Key? key}) {
    // E1：类型判定委托至 bubble_meta（可单测）。
    final bool isImage = isImageMessageType(msg.type.name);
    // E1：类型判定委托至 bubble_meta（可单测）。
    final bool isFile = isFileMessageType(msg.type.name);
    // E1：音频判定收敛至 bubble_meta.isAudioMessageType。
    final bool isAudio = isAudioMessageType(msg.type.name);
    // E1：气泡状态快照抽至 transfer_state_map.bubbleFlagsOf。
    final flags = bubbleFlagsOf(msg.transferState);
    final bool isTransferring = flags.isTransferring;
    final bool isFailed = flags.isFailed;
    final bool isSending = flags.isSending;

    // 音频消息使用专用气泡
    if (isAudio) {
      return _buildAudioBubbleRow(msg);
    }

    return Padding(
      key: key,
      // E1：纵向边距收敛至 bubble_meta.bubblePaddingV。
      padding: EdgeInsets.symmetric(vertical: bubblePaddingV()),
      child: Row(
        // E1：收敛至 bubble_meta.bubbleAlignmentIsEnd。
        mainAxisAlignment: bubbleAlignmentIsEnd(msg.isMe)
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!msg.isMe)
            CircleAvatar(
              // E1：底色抽至 bubble_meta.chatAvatarBg。
              backgroundColor: Color(chatAvatarBg(isMe: false)),
              // E1：半径收敛至 bubble_meta.avatarRadius。
              radius: avatarRadius(),
              child: Text(
                // E1：抽至 bubble_meta.avatarLetter。
                avatarLetter(widget.title),
                // E1：纯白收敛至 bubble_meta.bubbleWhite（宿主包 Color）。
                style: TextStyle(color: Color(bubbleWhite()), fontSize: 14),
              ),
            ),
          const SizedBox(width: 8),
          Flexible(
            child: Builder(
              builder: (bubbleCtx) {
                // E1：抽至 bubble_meta.canLongPressBubble/avatarLetter。
                final bool canLongPress = canLongPressBubble(
                  isTransferring: isTransferring,
                  isSending: isSending,
                  isFile: isFile,
                  content: msg.content,
                );
                // E1：图片气泡门控委托至 bubble_meta.shouldShowImageBubble。
                final bubbleChild = shouldShowImageBubble(isImage: isImage, imagePath: msg.imagePath)
                    ? _buildImageBubble(msg)
                    : _buildContentBubble(
                        msg,
                        isFile,
                        isTransferring,
                        isFailed,
                      );
                if (!canLongPress) return bubbleChild;
                // E1：平台判定抽至 message_actions.isDesktopBubble。
                final isDesktop = isDesktopBubble(
                  Platform.isWindows,
                  Platform.isMacOS,
                  Platform.isLinux,
                );
                // E1：动作分发抽至 message_actions.bubbleActionKind。
                void showBubbleByKind() {
                  final kind = bubbleActionKind(
                    isFile: isFile,
                    state: msg.transferState.name,
                    filePath: msg.filePath,
                    content: msg.content,
                  );
                  // E1：分支判定委托至 message_actions（可单测）。
                  if (isFileBubbleKind(kind)) {
                    _showActionBubbleFromContext(
                      bubbleCtx,
                      _buildFileActions(msg),
                    );
                  // E1：分支判定委托至 message_actions（可单测）。
                  } else if (isCopyBubbleKind(kind)) {
                    _showActionBubbleFromContext(
                      bubbleCtx,
                      _buildCopyAction(msg),
                    );
                  }
                }
                return GestureDetector(
                  // 桌面端：右键弹出；移动端：长按弹出
                  // E1：门控抽至 transfer_state_map.canShowFileActions/canShowCopyAction。
                  onSecondaryTapDown: isDesktop
                      ? (_) {
                          showBubbleByKind();
                        }
                      : null,
                  onLongPressStart: !isDesktop
                      ? (_) {
                          showBubbleByKind();
                        }
                      : null,
                  child: bubbleChild,
                );
              },
            ),
          ),
          if (msg.isMe && isSending)
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 8),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CupertinoActivityIndicator(radius: 7),
              ),
            ),
          const SizedBox(width: 8),
          if (msg.isMe)
            CircleAvatar(
              // E1：底色抽至 bubble_meta.chatAvatarBg。
              backgroundColor: Color(chatAvatarBg(isMe: true)),
              // E1：半径收敛至 bubble_meta.avatarRadius。
              radius: avatarRadius(),
              child: Text(
                // E1：抽至 bubble_meta.selfAvatarLetter。
                selfAvatarLetter(),
                // E1：纯白收敛至 bubble_meta.bubbleWhite（宿主包 Color）。
                style: TextStyle(color: Color(bubbleWhite()), fontSize: 14),
              ),
            ),
        ],
      ),
    );
  }

  /// 音频气泡行
  Widget _buildAudioBubbleRow(ChatMessage msg) {
    // E1：气泡状态快照抽至 transfer_state_map.bubbleFlagsOf。
    final flags = bubbleFlagsOf(msg.transferState);
    final isTransferring = flags.isTransferring;
    final isFailed = flags.isFailed;

    return Padding(
      // E1：纵向边距收敛至 bubble_meta.bubblePaddingV。
      padding: EdgeInsets.symmetric(vertical: bubblePaddingV()),
      child: Row(
        // E1：收敛至 bubble_meta.bubbleAlignmentIsEnd。
        mainAxisAlignment: bubbleAlignmentIsEnd(msg.isMe)
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (!msg.isMe)
            CircleAvatar(
              // E1：底色抽至 bubble_meta.chatAvatarBg（纯函数可单测）。
              backgroundColor: Color(chatAvatarBg(isMe: false)),
              // E1：半径收敛至 bubble_meta.avatarRadius。
              radius: avatarRadius(),
              child: Text(
                // E1：抽至 bubble_meta.avatarLetter。
                avatarLetter(widget.title),
                // E1：纯白收敛至 bubble_meta.bubbleWhite（宿主包 Color）。
                style: TextStyle(color: Color(bubbleWhite()), fontSize: 14),
              ),
            ),
          // E1：间距收敛至 bubble_meta.bubbleGap。
          SizedBox(width: bubbleGap()),
          if (isTransferring)
            Flexible(child: _buildAudioTransferring(msg))
          else ...[
            Flexible(
              child: AudioBubble(msg: msg, audioService: _audioService),
            ),
            // 失败时在气泡旁边显示红色感叹号，不显示失败文字
            if (isFailed)
              GestureDetector(
                // E1：门控抽至 bubble_meta.canRetryAudioTap（纯函数可单测）。
                onTap: canRetryAudioTap(isMe: msg.isMe, filePath: msg.filePath)
                    ? () => _trySend(
                        type: SendActionType.audioRetry,
                        retryMsg: msg,
                      )
                    : null,
                child: Padding(
                  padding: const EdgeInsets.only(left: 6),
                  // E1：错误色/尺寸收敛至 bubble_meta（宿主包 Color）。
                  child: Icon(
                    Icons.error,
                    color: Color(bubbleErrorColor()),
                    size: bubbleErrorIconSize(),
                  ),
                ),
              ),
          ],
          // E1：间距收敛至 bubble_meta.bubbleGap。
          SizedBox(width: bubbleGap()),
          if (msg.isMe)
            CircleAvatar(
              // E1：底色抽至 bubble_meta.chatAvatarBg。
              backgroundColor: Color(chatAvatarBg(isMe: true)),
              // E1：半径收敛至 bubble_meta.avatarRadius。
              radius: avatarRadius(),
              child: Text(
                // E1：抽至 bubble_meta.selfAvatarLetter。
                selfAvatarLetter(),
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
        ],
      ),
    );
  }

  /// 音频传输中占位
  Widget _buildAudioTransferring(ChatMessage msg) {
    // E1：底色抽至 bubble_meta.audioTransferBubbleColor（纯函数可单测）。
    return Container(
      width: 140,
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Color(audioTransferBubbleColor(isMe: msg.isMe)),
        // E1：圆角收敛至 media_layout.contentBubbleRadius。
        borderRadius: BorderRadius.circular(contentBubbleRadius()),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text(
            // E1：抽至 bubble_meta.formatProgressPercent。
            formatProgressPercent(msg.progress),
            // E1：次文案色收敛至 bubble_meta.bubbleSubTextColor（宿主包 Color）。
            style: TextStyle(fontSize: 12, color: Color(bubbleSubTextColor())),
          ),
          if (msg.isMe) ...[
            const SizedBox(width: 6),
            GestureDetector(
              onTap: () => _cancelTransfer(msg),
              // E1：取消图标色收敛至 bubble_meta.bubbleCancelFg（宿主包 Color）。
              child: Icon(
                Icons.close,
                size: 14,
                color: Color(bubbleCancelFg()),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 重新发送失败的音频消息（v2：语音 = 单文件会话，等待/进度/完成由 _sendViaLs 回写）
  Future<void> _retrySendAudio(ChatMessage msg) async {
    if (!isNotNull(msg.filePath)) return; // E1：非空判定委托

    // 文件已删除：直接标失败（语音用专用文案，不走通用缺文件占位）
    final file = File(msg.filePath!);
    if (!await file.exists()) {
      final idx = findFirstIndexById(chatData, (m) => m.id, msg.id);
      if (isMissingIndex(idx) || !mounted) return; // E1：未命中委托
      setState(() {
        // E1：文案抽至 TransferTexts.audioMissingContent。
        // E1：失败变异收敛至 TransferTexts.markAudioMissing。
        chatData = replaceAt(chatData, idx, TransferTexts.markAudioMissing(
          msg,
          TransferTexts.audioMissingContent(
            // E1：音频判定收敛至 bubble_meta.isAudioMessageType。
            isAudio: isAudioMessageType(msg.type.name),
            isFolder: false,
            // E1：文件名兜底收敛至 send_naming.fileNameOrEmpty。
            displayName: fileNameOrEmpty(msg.fileName),
          ),
        ));
      });
      _cacheService.updateMessage(widget.id, msg.id, chatData[idx]);
      return;
    }

    // v2：复用通用发送管线；existingMsg 重用原气泡，
    // waitingContentOverride 保持语音文案（不写成文件等待文案）
    final item = await _prepareSendItem(
      msg.filePath!,
      // E1：文件名兜底抽至 send_naming.fileNameOrAudio。
      fileNameOrAudio(msg.fileName),
      isVoice: true,
      durationMs: msg.durationMs,
      waveformData: msg.waveformData,
      existingMsg: msg,
      waitingContentOverride: TransferTexts.audioWaitingContent(),
    );
    if (item == null) return;
    await _sendViaLs([item]);
  }

  // 旧握手逻辑已移除：file_notify / file_accept / TCP sendFile 由 v2 会话取代

  /// 文字/文件气泡
  Widget _buildImageBubble(ChatMessage msg) {
    // E1：气泡状态快照抽至 transfer_state_map.bubbleFlagsOf。
    final flags = bubbleFlagsOf(msg.transferState);
    final bool isTransferring = flags.isTransferring;
    final bool isFailed = flags.isFailed;
    final bool isCompleted = flags.isCompleted;

    // 确定用于显示的图片路径：优先缩略图，其次原图路径
    // E1：抽至 bubble_meta.resolveDisplayImagePath/resolveOriginalImagePath/
    // isImageMissing/formatProgressPercent/shouldShowCancel。
    final displayPath = resolveDisplayImagePath(
      thumb: msg.thumbnailPath,
      image: msg.imagePath,
      file: msg.filePath,
    );
    // 原图路径用于全屏预览
    final originalPath = resolveOriginalImagePath(
      image: msg.imagePath,
      file: msg.filePath,
    );
    // 检查文件是否存在（使用缓存避免 UI 线程阻塞）
    // E1：双路读写收敛至 lookupOrProbeExists，此处仅薄委托。
    var fileExists = _imgCache.lookupOrProbeExists(
      displayPath,
      (p) => File(p).existsSync(),
    );
    var originalExists = _imgCache.lookupOrProbeExists(
      originalPath,
      (p) => File(p).existsSync(),
    );

    // 文件缺失状态（已完成但文件不存在）
    // E1：抽至 bubble_meta.isImageMissing。
    final bool isMissing = isImageMissing(
      isCompleted: isCompleted,
      fileExists: fileExists,
      originalExists: originalExists,
    );

    // 获取图片实际尺寸，用于按比例缩放（异步解码 + 缓存）
    // E1：读写抽至 image_existence_cache（Size.zero 表解码失败）。
    // E1：哨兵解码抽至 bubble_meta.resolveCachedSize。
    Size? imageSize;
    if (fileExists) {
      final cached = _imgCache.lookupSize(displayPath);
      final cz = cached;
      if (isNotNull(cz)) { // E1：非空判定委托
        imageSize = resolveCachedSize(cz, Size.zero);
      } else {
        // 异步解码图片尺寸，完成后刷新 UI
        final path = displayPath!; // ignore: unnecessary_non_null_assertion
        _decodeImageSize(path).then((size) {
          if (mounted) {
            // E1：回退抽至 bubble_meta.sizeOrZero。
            _imgCache.storeSize(path, sizeOrZero(size, Size.zero));
            if (isNotNull(size)) { // E1：非空判定委托
              setState(() {}); // 用实际尺寸重新渲染
            }
          }
        });
      }
    }

    // 计算显示尺寸：基于比例，限制最大宽度和最大高度
    // E1：抽至 media_layout.calcImageDisplaySize。
    final displaySize = calcImageDisplaySize(
      imageSize: imageSize,
      screenWidth: MediaQuery.of(context).size.width,
    );
    double displayWidth = displaySize.width;
    double displayHeight = displaySize.height;

    final Widget imageContent;
    if (isMissing) {
      imageContent = _buildMissingImagePlaceholder(
        width: displayWidth,
        height: displayHeight,
      );
    } else if (displayPath != null && fileExists) {
      imageContent = GestureDetector(
        // E1：门控抽至 bubble_meta.canPreviewImage（纯函数可单测）。
        onTap: canPreviewImage(
                isCompleted: isCompleted,
                originalExists: originalExists,
                originalPath: originalPath,
              )
            // E1：!收敛至 bubble_meta.requirePreviewPath。
            ? () => _openImageViewer(requirePreviewPath(originalPath), imageViewerTitle(fileName: msg.fileName))
            : null,
        child: Image.file(
          File(displayPath),
          fit: BoxFit.contain,
          width: displayWidth,
          height: displayHeight,
          errorBuilder: (context, error, stackTrace) {
            return _buildMissingImagePlaceholder(
              width: displayWidth,
              height: displayHeight,
            );
          },
        ),
      );
    } else {
      // 传输中但还没有缩略图，显示占位图
      imageContent = _buildImagePlaceholder(
        width: displayWidth,
        height: displayHeight,
        fileName: msg.fileName,
      );
    }

    return ClipRRect(
      // E1：圆角收敛至 media_layout.imageBubbleRadius。
      borderRadius: BorderRadius.circular(imageBubbleRadius()),
      child: Container(
        width: displayWidth,
        height: displayHeight,
        decoration: BoxDecoration(
          // E1：占位底收敛至 bubble_meta.imagePlaceholderBg（宿主包 Color）。
          color: Color(imagePlaceholderBg()),
          border: Border.all(
            // E1：判定抽至 bubble_meta.shouldUseErrorBorder（图片/文件共用）。
            // E1：边框色收敛至 bubble_meta.bubbleFileBorderColor（宿主包 Color）。
            color: Color(
              bubbleFileBorderColor(
                failed: shouldUseErrorBorder(
                  isFailed: isFailed,
                  isMissing: isMissing,
                ),
              ),
            ),
            width: 0.5,
          ),
          // E1：圆角收敛至 media_layout.imageBubbleRadius。
          borderRadius: BorderRadius.circular(imageBubbleRadius()),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 图片显示区域
            imageContent,

            // 传输中遮罩
            if (isTransferring)
              Positioned.fill(
                child: Container(
                  // E1：遮罩收敛至 bubble_meta.imageMaskColor（宿主包 Color）。
                  color: Color(imageMaskColor()),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CupertinoActivityIndicator(
                        radius: 14,
                        // E1：纯白收敛至 bubble_meta.bubbleWhite。
                        color: Color(bubbleWhite()),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        // E1：抽至 bubble_meta.formatProgressPercent/shouldShowCancel。
                        formatProgressPercent(msg.progress),
                        // E1：纯白收敛至 bubble_meta.bubbleWhite（宿主包 Color）。
                        style: TextStyle(
                          color: Color(bubbleWhite()),
                          fontSize: 13,
                        ),
                      ),
                      // 取消按钮：发送端始终显示；接收端仅在非自动接收时显示
                      // E1：抽至 bubble_meta.shouldShowCancel。
                      if (shouldShowCancel(
                        isMe: msg.isMe,
                        autoReceive: _autoReceive,
                      )) ...[
                        const SizedBox(height: 6),
                        GestureDetector(
                          onTap: () => _cancelTransfer(msg),
                          child: Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              // E1：底收敛至 bubble_meta.imageCancelBg（宿主包 Color）。
                              color: Color(imageCancelBg()),
                              shape: BoxShape.circle,
                            ),
                            // E1：纯白收敛至 bubble_meta.bubbleWhite（宿主包 Color）。
                            child: Icon(
                              Icons.close,
                              size: 14,
                              color: Color(bubbleWhite()),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            // 失败遮罩（覆盖在缩略图上方，用户仍能看到图片内容）
            if (isFailed)
              Positioned.fill(
                child: Container(
                  // E1：失败遮罩收敛至 bubble_meta.imageFailMaskColor（宿主包 Color）。
                  color: Color(imageFailMaskColor()),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // E1：取消前景收敛至 bubble_meta.bubbleCancelFg（宿主包 Color）。
                      Icon(
                        Icons.error_outline,
                        color: Color(bubbleCancelFg()),
                        size: 28,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        imageFailText(isMe: msg.isMe),
                        // E1：取消前景收敛至 bubble_meta.bubbleCancelFg（宿主包 Color）。
                        style: TextStyle(
                          color: Color(bubbleCancelFg()),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      // 发送端显示重试按钮
                      if (msg.isMe) ...[
                        const SizedBox(height: 4),
                        GestureDetector(
                          onTap: () {
                            if (isNotNull(msg.filePath)) { // E1：非空判定委托
                              _trySend(
                                type: SendActionType.image,
                                filePath: msg.filePath!,
                                // E1：文件名兜底抽至 send_naming.fileNameOrImage。
                                fileName: fileNameOrImage(msg.fileName),
                                isFolder: msg.isFolder,
                                retryMsg: msg,
                              );
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              // E1：胶囊底收敛至 bubble_meta.retryChipBg（宿主包 Color）。
                              color: Color(retryChipBg()),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              imageRetryText(),
                              // E1：浅红收敛至 bubble_meta.bubbleRedLight（宿主包 Color）。
                              style: TextStyle(
                                fontSize: 11,
                                color: Color(bubbleRedLight()),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ],
                      // 接收端：点击请求对方重新发送（仅非自动接收时）
                      if (!msg.isMe && !_autoReceive) ...[
                        const SizedBox(height: 4),
                        GestureDetector(
                          onTap: () {
                            // v2：告知 ChatListPage 用户已请求重发（协议层无需预注册，
                            // 重发由发送方走 prepare-upload 主动发起）
                            // E1：回调空安全调用留宿主（?.call透传，宿主直接调用）。
                            widget.onManualAcceptFile?.call(
                              widget.id,
                              // E1：文件名兜底收敛至 send_naming.fileNameOrEmpty。
                              fileNameOrEmpty(msg.fileName),
                              msg.transferId,
                              sessionId: msg.sessionId,
                            );
                            // E1：查找抽至 device_lookup.findFirstIndexById。
                            final index = findFirstIndexById(
                              chatData,
                              (m) => m.id,
                              msg.id,
                            );
                            if (hasFoundIndex(index)) /* E1：命中委托 */ {
                              setState(() {
                                // E1：文案抽至 TransferTexts.waitPeerResendContent。
                                // E1：等待变异收敛至 TransferTexts.markWaiting。
                                chatData = replaceAt(chatData, index, TransferTexts.markWaiting(
                                  msg,
                                  TransferTexts.waitPeerResendContent(
                                    // E1：文件名兜底收敛至 send_naming.fileNameOrEmpty。
                                    fileNameOrEmpty(msg.fileName),
                                  ),
                                ));
                              });
                              _cacheService.updateMessage(
                                widget.id,
                                msg.id,
                                chatData[index],
                              );
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              // E1：胶囊底收敛至 bubble_meta.retryChipBg（宿主包 Color）。
                              color: Color(retryChipBg()),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              imageResumeText(),
                              // E1：浅蓝收敛至 bubble_meta.bubbleBlueLight（宿主包 Color）。
                              style: TextStyle(
                                fontSize: 11,
                                color: Color(bubbleBlueLight()),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 图片文件缺失时的占位UI（不可点击）
  Widget _buildMissingImagePlaceholder({
    double width = 140,
    double height = 140,
  }) {
    return Container(
      width: width,
      height: height,
      // E1：占位底收敛至 bubble_meta.imagePlaceholderBg（宿主包 Color）。
      color: Color(imagePlaceholderBg()),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // E1：占位灰收敛至 bubble_meta.bubbleGrey400（宿主包 Color）。
          Icon(
            Icons.image_not_supported_outlined,
            size: 40,
            color: Color(bubbleGrey400()),
          ),
          const SizedBox(height: 8),
          Text(
            missingImageText(),
            // E1：占位灰收敛至 bubble_meta.bubbleGrey400（宿主包 Color）。
            style: TextStyle(fontSize: 12, color: Color(bubbleGrey400())),
          ),
        ],
      ),
    );
  }

  /// 传输中无缩略图时的占位（显示文件名和图片图标）
  Widget _buildImagePlaceholder({
    required double width,
    required double height,
    String? fileName,
  }) {
    return Container(
      width: width,
      height: height,
      // E1：占位底收敛至 bubble_meta.imagePlaceholderBg（宿主包 Color）。
      color: Color(imagePlaceholderBg()),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // E1：占位灰收敛至 bubble_meta.bubbleGrey400（宿主包 Color）。
          Icon(
            Icons.image_outlined,
            size: 36,
            color: Color(bubbleGrey400()),
          ),
          const SizedBox(height: 8),
          if (fileName != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                fileName,
                // E1：次级灰收敛至 bubble_meta.bubbleGrey500（宿主包 Color）。
                style: TextStyle(
                  fontSize: 11,
                  color: Color(bubbleGrey500()),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    );
  }

  /// 打开图片全屏预览
  void _openImageViewer(String imagePath, String title) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _ImageViewerPage(imagePath: imagePath, title: title),
      ),
    );
  }

  /// 接收到的 zip 文件自动解压为同名文件夹（模拟 Flix/LocalSend 行为）
  Future<void> _extractReceivedZip(
    String zipPath,
    String zipFileName,
    ChatMessage msg,
  ) async {
    Directory? dirForCleanup;
    try {
      final zipFile = File(zipPath);
      if (!await zipFile.exists()) {
        // E1：zip跳过日志收敛至 chat_debug_logs.zipSkipLog。
        debugPrint(zipSkipLog(zipPath));
        return;
      }

      // P0-6：zip 本体超大直接拒绝（保留原文件，不解压），避免 decodeBytes OOM
      final zipLen = await zipFile.length();
      // E1：zip 超限门控收敛至 media_layout.isZipTooLarge。
      if (isZipTooLarge(length: zipLen, maxBytes: _maxZipFileSize)) {
        // E1：zip超限日志收敛至 chat_debug_logs.zipTooLargeLog。
        debugPrint(zipTooLargeLog(formatFileSize(zipLen)));
        if (mounted) {
          // E1：文案抽至 send_waiting_texts.extractTooLargeText。
          showCenterToast(context, extractTooLargeText(zipFileName));
        }
        return;
      }

      // E1：解压开始日志收敛至 chat_debug_logs.zipStartLog。
      debugPrint(zipStartLog(zipPath));

      // 解压到同名文件夹（去掉 .zip 后缀），重名时加序号（U5：`name (1)`）。
      // E1：基名抽至 extract_naming（纯函数可单测），序号循环保留（IO 存在检查）。
      // E1：序号名抽至 media_layout.nextIndexedFolderName。
      final folderName = extractFolderBase(zipFileName);
      final parentDir = pth.dirname(zipPath);
      String finalName = folderName;
      var counter = 1;
      while (await Directory(pth.join(parentDir, finalName)).exists()) {
        finalName = nextIndexedFolderName(folderName, counter);
        counter++;
      }
      final targetDir = Directory(pth.join(parentDir, finalName));
      // 赋值给外层，供 catch 清理半解压目录
      // ignore: prefer_final_locals
      dirForCleanup = targetDir;

      // 读取并解压档案
      // D4 注：当前为全量读入解压（简单可靠）；超大 zip 已由 _maxZipFileSize 预检拦截，
      // 流式解压可后续优化。解压前对 entry.name 做二次校验，含 .. 直接跳过。
      final zipBytes = await zipFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(zipBytes);

      // E1：zip条目日志收敛至 chat_debug_logs.zipCountLog。
      debugPrint(zipCountLog(archive.files.length));

      // 检测所有条目是否共享一个顶层目录前缀。
      // 发送端把整个文件夹打包时，所有路径都以文件夹名开头，
      // 而 targetDir 本身就是以该文件夹名命名的,
      // 如果不剥离前缀会导致 targetDir/folderName/file 的双层嵌套。
      // E1：前缀检测抽至 folder_archive_service.commonTopPrefix（纯函数）。
      final commonPrefix = FolderArchiveService.commonTopPrefix(
        archive.files.where((f) => f.isFile).map((f) => f.name),
      );
      // E1：前缀有效判定抽至 text_edit.hasCommonPrefix。
      if (hasCommonPrefix(commonPrefix)) {
        // E1：zip前缀日志收敛至 chat_debug_logs.zipPrefixLog。
        debugPrint(zipPrefixLog(commonPrefix));
      }

      // 创建目标目录
      await targetDir.create(recursive: true);

      int extractedCount = 0;
      int totalSize = 0;
      bool abortedByLimit = false;

      for (final archiveFile in archive.files) {
        // D4：解压前二次校验 entry.name，含 .. 直接跳过（防穿越）。
        // E1：抽至 media_layout.isSuspiciousZipEntry。
        if (isSuspiciousZipEntry(archiveFile.name)) {
          // E1：可疑条目日志收敛至 chat_debug_logs.zipSuspiciousLog。
          debugPrint(zipSuspiciousLog(archiveFile.name));
          continue;
        }
        // E1：安全路径清洗抽至 folder_archive_service.safeZipEntryPath
        // （去 \ / 开头 ../ / 中间 ./../ / 剥离顶层共同前缀，纯函数）。
        final safePath = FolderArchiveService.safeZipEntryPath(
          archiveFile.name,
          commonPrefix: commonPrefix,
        );

        // E1：空路径跳过抽至 text_edit.isEmptyPath（保持 continue）。
        if (isEmptyPath(safePath)) continue;

        if (archiveFile.isFile) {
          // E1：content断言收敛至 folder_archive_service.zipEntryBytes（保持continue）。
          final content = FolderArchiveService.zipEntryBytes(archiveFile.content);
          if (content == null) continue;
          // ZIP 炸弹防护：累计大小超过上限则中止（P0-6：中止后删半解压目录，保留 zip）
          // E1：抽至 media_layout.exceedsExtractLimit。
          if (exceedsExtractLimit(
            total: totalSize,
            add: content.length,
            limit: _maxExtractTotalSize,
          )) {
            // E1：超限中止日志收敛至 chat_debug_logs.zipOverLimitLog。
            debugPrint(
              zipOverLimitLog(
                formatFileSize(_maxExtractTotalSize),
              ),
            );
            abortedByLimit = true;
            break;
          }

          // E1：解压输出路径收敛至 media_layout.joinExtractOutputPath。
          final outFilePath = joinExtractOutputPath(targetDir.path, safePath);
          final outFile = File(outFilePath);

          // 最终防线：确保解压路径在目标目录内
          // E1：抽至 media_layout.isPathInside。
          if (!isPathInside(
            targetAbs: targetDir.absolute.path,
            childAbs: outFile.absolute.path,
          )) {
            // E1：穿越拦截日志收敛至 chat_debug_logs.zipTraversalLog。
            debugPrint(zipTraversalLog(safePath));
            continue;
          }

          // 创建父目录
          await outFile.parent.create(recursive: true);

          // 写入文件内容
          await outFile.writeAsBytes(content);
          extractedCount++;
          totalSize += content.length;
        } else {
          // 目录条目：创建空目录，保留完整文件夹结构
          // E1：解压输出路径收敛至 media_layout.joinExtractOutputPath。
          final dirPath = joinExtractOutputPath(targetDir.path, safePath);
          // 目录也需要路径穿越检测
          // E1：抽至 media_layout.isPathInside。
          if (!isPathInside(
            targetAbs: targetDir.absolute.path,
            childAbs: Directory(dirPath).absolute.path,
          )) {
            // E1：目录穿越日志收敛至 chat_debug_logs.zipTraversalDirLog。
            debugPrint(zipTraversalDirLog(safePath));
            continue;
          }
          await Directory(dirPath).create(recursive: true);
        }
      }

      // 解压完成后删除原始 zip
      if (abortedByLimit) {
        // P0-6：超限中止——删半解压目录、保留 zip，消息标失败可手动处理
        try {
          if (await targetDir.exists()) {
            await targetDir.delete(recursive: true);
          }
        } catch (_) {}
        // E1：超限清理日志收敛至 chat_debug_logs.zipOverLimitCleanedLog。
        debugPrint(zipOverLimitCleanedLog(zipPath));
        if (mounted) {
          // E1：文案抽至 send_waiting_texts.extractAbortedText。
          showCenterToast(context, extractAbortedText(zipFileName));
        }
        final idx = findFirstIndexById(chatData, (m) => m.id, msg.id);
        if (hasFoundIndex(idx) /* E1：命中委托 */ && mounted) {
          // E1：失败变异收敛至 TransferTexts.markExtractAborted。
          final failed = TransferTexts.markExtractAborted(
            chatData[idx],
            extractAbortedContent(zipFileName),
          );
          setState(() {
            chatData = replaceAt(chatData, idx, failed);
          });
          _cacheService.updateMessage(widget.id, failed.id, failed);
        }
        return;
      }
      await zipFile.delete();

      // E1：解压完成日志收敛至 chat_debug_logs.zipDoneLog。
      debugPrint(
        zipDoneLog(
          folderName,
          extractedCount,
          formatFileSize(totalSize),
        ),
      );

      if (!mounted) return;

      // 更新消息气泡：路径指向文件夹，内容改为文件夹显示
      final idx = findFirstIndexById(chatData, (m) => m.id, msg.id);
      if (hasFoundIndex(idx)) /* E1：命中委托 */ {
        final updated = chatData[idx].copyWith(
          filePath: targetDir.path,
          content: extractDoneContent(folderName),
          fileName: folderName,
          fileSize: extractCountText(extractedCount),
        );
        setState(() {
          chatData = replaceAt(chatData, idx, updated);
        });
        _cacheService.updateMessage(widget.id, updated.id, updated);
      }
    } catch (e) {
      // E1：zip失败日志收敛至 chat_debug_logs.zipFailLog。
      debugPrint(zipFailLog(e));
      // P0-6：解压异常——删半解压目录、保留原始 zip（可手动处理），不改消息为完成
      try {
        final dir = dirForCleanup;
        if (dir != null && await dir.exists()) {
          await dir.delete(recursive: true);
        }
      } catch (_) {}
      // 解压失败保留原始 zip，不删也不改消息
    }
  }

  /// 音频传输完成后补全元数据（P1-7：优先播放器真实时长，波形缺省才回退生成）
  Future<void> _updateAudioMeta(String filePath, ChatMessage msg) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return;

      int durationMs = msg.durationMs;
      // E1：时长探测门控收敛至 bubble_meta.needsDurationProbe。
      if (needsDurationProbe(durationMs)) {
        durationMs = await _audioService.durationOf(filePath);
      }
      // E1：无效时长门控收敛至 bubble_meta.isInvalidDuration。
      if (isInvalidDuration(durationMs)) return;

      // E1：波形回退抽至 TransferTexts.resolveAudioWaveform。
      final waveformData = TransferTexts.resolveAudioWaveform(
        existing: msg.waveformData,
        fallback: _encodeWaveformFromAmps(const []),
      );

      final idx = findFirstIndexById(chatData, (m) => m.id, msg.id);
      if (hasFoundIndex(idx) /* E1：命中委托 */ && mounted) {
        // E1：元数据变异收敛至 TransferTexts.markAudioMeta。
        final updatedMsg = TransferTexts.markAudioMeta(
          chatData[idx],
          durationMs: durationMs,
          waveformData: waveformData,
          // E1：恒定标签抽至 emoji_bubble_texts.audioLabel。
          content: audioLabel(),
        );
        setState(() {
          chatData = replaceAt(chatData, idx, updatedMsg);
        });
        _cacheService.updateMessage(widget.id, updatedMsg.id, updatedMsg);
      }
    } catch (e) {
      // E1：音频元数据日志收敛至 chat_debug_logs.audioMetaFailLog。
      debugPrint(audioMetaFailLog(e));
    }
  }

  /// 异步解码图片尺寸（不阻塞 UI），返回 null 表示解码失败
  Future<Size?> _decodeImageSize(String imagePath) async {
    try {
      final file = File(imagePath);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final size = Size(
        frame.image.width.toDouble(),
        frame.image.height.toDouble(),
      );
      frame.image.dispose();
      codec.dispose();
      return size;
    } catch (e) {
      // E1：解码尺寸日志收敛至 chat_debug_logs.decodeSizeFailLog。
      debugPrint(decodeSizeFailLog(e));
      return null;
    }
  }

  /// P1-10：缩略图 LRU——超过上限删最旧，避免无限堆积
  // E1：三清理抽至 cache_maintenance（CacheMaintenance 纯 IO，可单测）。
  Future<void> _pruneThumbnails() => CacheMaintenance.pruneThumbnails(
    _thumbnailDir,
    maxFiles: _maxThumbFiles,
  );

  /// D3：缓存配额——thumbnails 已有 200 上限（_pruneThumbnails）；
  /// 语音/图片原文件走 7 天清理（_cleanupStaleCache），避免无限堆积。
  Future<void> _cleanupStaleCache() async {
    try {
      final docDir = await getApplicationDocumentsDirectory();
      await CacheMaintenance.cleanupStaleCache(docDir.path);
    } catch (e) {
      // E1：陈旧缓存日志收敛至 chat_debug_logs.staleCacheFailLog。
      debugPrint(staleCacheFailLog(e));
    }
  }

  Future<void> _cleanupStaleTempZips() async {
    try {
      final tempDir = await getTemporaryDirectory();
      await CacheMaintenance.cleanupStaleTempZips(tempDir.path);
    } catch (e) {
      // E1：临时zip日志收敛至 chat_debug_logs.tempZipFailLog。
      debugPrint(tempZipFailLog(e));
    }
  }

  /// 生成缩略图，返回缩略图路径；失败返回 null（降级使用原图）
  Future<String?> _generateThumbnail(String imagePath, String fileName) async {
    if (_thumbnailDir == null) return null;
    if (!_isImageCompressSupported) {
      // E1：缩略图不支持日志收敛至 chat_debug_logs.thumbUnsupportedLog。
      debugPrint(thumbUnsupportedLog());
      return null;
    }
    try {
      final srcFile = File(imagePath);
      if (!await srcFile.exists()) {
        // E1：缩略图缺源日志收敛至 chat_debug_logs.thumbSrcMissingLog。
        debugPrint(thumbSrcMissingLog(imagePath));
        return null;
      }

      final thumbName = buildThumbName(
        fileName: fileName,
        nowMs: nowMs() /* E1：时钟收敛至 app_clock.nowMs */,
      );
      // E1：路径抽至 send_naming.buildThumbPath（上已判空，此处收窄）。
      final thumbDir = _thumbnailDir;
      if (thumbDir == null) return null;
      final thumbPath = buildThumbPath(thumbDir: thumbDir, thumbName: thumbName);

      // E1：压缩参数抽至 media_layout.thumbCompressParams。
      final thumbParams = thumbCompressParams();
      final result = await FlutterImageCompress.compressAndGetFile(
        imagePath,
        thumbPath,
        quality: thumbParams.quality,
        minWidth: thumbParams.minWidth,
        minHeight: thumbParams.minHeight,
        format: CompressFormat.jpeg,
      );

      if (result != null) {
        // E1：缩略图成功日志收敛至 chat_debug_logs.thumbOkLog。
        debugPrint(thumbOkLog(thumbPath));
        return result.path;
      }
      return null;
    } catch (e) {
      // E1：缩略图失败日志收敛至 chat_debug_logs.thumbFailLog。
      debugPrint(thumbFailLog(e));
      return null;
    }
  }

  /// 文字/文件气泡
  Widget _buildContentBubble(
    ChatMessage msg,
    bool isFile,
    bool isTransferring,
    bool isFailed,
  ) {
    // E1：底色/边框判定抽至 bubble_meta（纯函数可单测），此处仅薄委托。
    final bubbleFailed = shouldUseErrorBorder(isFailed: isFailed, isMissing: false);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Color(contentBubbleColor(isMe: msg.isMe, isFile: isFile)),
        // E1：圆角收敛至 media_layout.contentBubbleRadius。
        borderRadius: BorderRadius.circular(contentBubbleRadius()),
        border: isFile
            ? Border.all(
                // E1：边框色收敛至 bubble_meta.bubbleFileBorderColor（宿主包 Color）。
                color: Color(bubbleFileBorderColor(failed: bubbleFailed)),
                width: 0.5,
              )
            : null,
        boxShadow: [
          BoxShadow(
            // E1：阴影收敛至 bubble_meta.bubbleShadowColor（宿主包 Color）。
            color: Color(bubbleShadowColor()),
            blurRadius: 2,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 文件图标 + 文件名
          if (isFile) ...[
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  // E1：文件名兜底收敛至 send_naming.fileNameOrEmpty（switch 本体不动）。
                  _getFileIcon(fileNameOrEmpty(msg.fileName), isFolder: msg.isFolder),
                  // E1：尺寸收敛至 media_layout.fileIconSize。
                  size: fileIconSize(),
                  // E1：前景抽至 bubble_meta.fileIconFg（纯函数可单测）。
                  color: Color(fileIconFg(isFailed: isFailed)),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        // E1：抽至 bubble_meta.folderDisplayName。
                        folderDisplayName(
                          fileName: msg.fileName,
                          isFolder: msg.isFolder,
                        ),
                        // E1：正文色收敛至 bubble_meta.bubbleTextColor（宿主包 Color）。
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Color(bubbleTextColor()),
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (msg.fileSize != null)
                        Text(
                          msg.fileSize!,
                          // E1：次级灰收敛至 bubble_meta.bubbleGrey500（宿主包 Color）。
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(bubbleGrey500()),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
          ],

          // 消息内容文本
          // E1：复制可见门控抽至 bubble_meta.shouldShowCopyForBubble。
          if (shouldShowCopyForBubble(content: msg.content, isFile: isFile))
            Text(
              msg.content,
              // E1：正文色收敛至 bubble_meta.bubbleTextColor（宿主包 Color）。
              style: TextStyle(
                fontSize: 16,
                color: Color(bubbleTextColor()),
                height: 1.4,
              ),
            )
          else if (isFile)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  msg.content,
                  // E1：状态色收敛至 bubble_meta.bubbleStatusColor（宿主包 Color，去内联三元）。
                  style: TextStyle(
                    fontSize: 12,
                    color: Color(bubbleStatusColor(failed: isFailed)),
                    height: 1.3,
                  ),
                ),
                // 接收端 pending：自动接收时显示转圈等待
                // E1：判定抽至 bubble_meta（纯函数可单测），此处仅薄委托。
                if (shouldShowPeerPendingWaiting(
                  isPeerPending: isPeerPending(
                    isMe: msg.isMe,
                    state: msg.transferState,
                  ),
                  autoReceive: _autoReceive,
                )) ...[
                  const SizedBox(width: 6),
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CupertinoActivityIndicator(radius: 7),
                  ),
                ],
              ],
            ),
          // 接收端 pending + 非自动接收：显示接收/拒绝操作按钮
          // E1：文案抽至 emoji_bubble_texts.pendingAcceptText/pendingRejectText。
          // E1：判定抽至 bubble_meta.shouldShowPeerPendingActions。
          if (shouldShowPeerPendingActions(
            isPeerPending: isPeerPending(
              isMe: msg.isMe,
              state: msg.transferState,
            ),
            autoReceive: _autoReceive,
          )) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildMiniButton(
                  pendingAcceptText(),
                  // E1：接受绿收敛至 bubble_meta.bubbleAcceptColor（宿主包 Color）。
                  Color(bubbleAcceptColor()),
                  () => _onUserAcceptPending(msg),
                ),
                const SizedBox(width: 10),
                _buildMiniButton(
                  pendingRejectText(),
                  // E1：取消前景收敛至 bubble_meta.bubbleCancelFg（宿主包 Color）。
                  Color(bubbleCancelFg()),
                  () => _onUserRejectPending(msg),
                ),
              ],
            ),
          ],

          // 进度条（传输中时显示）+ 取消按钮
          // 取消按钮：发送端始终显示；接收端仅在非自动接收时显示
          if (isTransferring) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                // E1：判定抽至 bubble_meta.progressBarValue。
                value: progressBarValue(msg.progress),
                minHeight: 4,
                // E1：轨底收敛至 bubble_meta.bubbleGrey200（宿主包 Color）。
                backgroundColor: Color(bubbleGrey200()),
                // E1：品牌绿收敛至 bubble_meta.bubbleBrandColor（宿主包 Color）。
                valueColor: AlwaysStoppedAnimation<Color>(
                  Color(bubbleBrandColor()),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  // E1：抽至 bubble_meta.formatProgressPercent/shouldShowCancel。
                  formatProgressPercent(msg.progress),
                  // E1：次级灰收敛至 bubble_meta.bubbleGrey500（宿主包 Color）。
                  style: TextStyle(fontSize: 11, color: Color(bubbleGrey500())),
                ),
                if (shouldShowCancel(
                  isMe: msg.isMe,
                  autoReceive: _autoReceive,
                )) ...[
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => _cancelTransfer(msg),
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        // E1：小取消底收敛至 bubble_meta.bubbleCancelBg（宿主包 Color）。
                        color: Color(bubbleCancelBg()),
                        shape: BoxShape.circle,
                      ),
                      // E1：取消前景收敛至 bubble_meta.bubbleCancelFg（宿主包 Color）。
                      child: Icon(
                        Icons.close,
                        size: 12,
                        color: Color(bubbleCancelFg()),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],

          // 失败重试按钮
          // E1：判定抽至 bubble_meta.shouldShowRetryAction（纯函数可单测）。
          if (shouldShowRetryAction(isFailed: isFailed, isMe: msg.isMe)) ...[
            const SizedBox(height: 6),
            GestureDetector(
              onTap: () async {
                // E1：文字判定收敛至 bubble_meta.isTextMessageType。
                if (isTextMessageType(msg.type.name)) {
                  // 文字消息重发
                  // E1：逆解析/标签/失败文案抽至 bubble_meta/TransferTexts，
                  // 拉黑门控抽至 text_retry_policy。
                  final text = extractOriginalTextForResend(msg.content);
                  // 更新 UI 为发送中
                  setState(() {
                    final index = findFirstIndexById(chatData, (m) => m.id, msg.id);
                    if (hasFoundIndex(index)) /* E1：命中委托 */ {
                      // E1：重发变异收敛至 TransferTexts.markTextSending。
                      chatData = replaceAt(chatData, index, TransferTexts.markTextSending(msg, text));
                    }
                  });
                  await _trySend(
                    type: SendActionType.text,
                    msgId: msg.id,
                    text: text,
                  );
                  // _trySend 中 _checkTargetOnline 已拉黑/被拉黑会导致静默返回，需回退 UI
                  if (mounted &&
                      shouldAbortTextRetry(
                        blockedLocal: _isBlocked,
                        blockedByPeer: _isBlockedByPeer,
                      )) {
                    setState(() {
                      final index = findFirstIndexById(chatData, (m) => m.id, msg.id);
                      if (hasFoundIndex(index)) /* E1：命中委托 */ {
                        // E1：变异抽至 TransferTexts.markTextFailed。
                        chatData = replaceAt(chatData, index, TransferTexts.markTextFailed(
                          chatData[index],
                          text,
                        ));
                      }
                    });
                  }
                } else if (isNotNull(msg.filePath)) { // E1：非空判定委托
                  // E1：重发类型映射抽至 send_dispatch.resolveRetrySendType。
                  _trySend(
                    type: resolveRetrySendType(msg.type),
                    filePath: msg.filePath!,
                    // E1：文件名兜底抽至 send_naming.fileNameOrFile。
                    fileName: fileNameOrFile(msg.fileName),
                    isFolder: msg.isFolder,
                    retryMsg: msg,
                  );
                }
              },
              child: Text(
                // E1：抽至 bubble_meta.retryLabel。
                // E1：抽至 bubble_meta.retryLabel/文字判定收敛至 isTextMessageType。
                retryLabel(isText: isTextMessageType(msg.type.name)),
                // E1：浅红收敛至 bubble_meta.bubbleRedLight（宿主包 Color）。
                style: TextStyle(fontSize: 12, color: Color(bubbleRedLight())),
              ),
            ),
          ],
          // 接收端失败/已拒绝：点击请求对方重新发送（仅非自动接收时有效）
          // E1：判定抽至 bubble_meta.shouldShowRequestResend（纯函数可单测）。
          if (shouldShowRequestResend(
            isFailed: isFailed,
            isMe: msg.isMe,
            autoReceive: _autoReceive,
          )) ...[
            const SizedBox(height: 6),
            GestureDetector(
              onTap: () {
                // E1：文件名兜底收敛至 send_naming.fileNameOrEmpty。
                final fileName = fileNameOrEmpty(msg.fileName);
                // v2：告知 ChatListPage 用户已请求重发（协议层无需预注册，
                // 重发由发送方走 prepare-upload 主动发起）
                // E1：回调空安全调用留宿主（?.call透传，宿主直接调用）。
                widget.onManualAcceptFile?.call(
                  widget.id,
                  fileName,
                  msg.transferId,
                  sessionId: msg.sessionId,
                );
                // 更新本地消息为"等待对方重新发送"
                // E1：文案抽至 TransferTexts.waitPeerResendContent。
                final index = findFirstIndexById(chatData, (m) => m.id, msg.id);
                if (hasFoundIndex(index)) /* E1：命中委托 */ {
                  setState(() {
                    // E1：等待变异收敛至 TransferTexts.markWaiting。
                    chatData = replaceAt(chatData, index, TransferTexts.markWaiting(
                      msg,
                      TransferTexts.waitPeerResendContent(
                        // E1：文件名兜底收敛至 send_naming.fileNameOrEmpty。
                        fileNameOrEmpty(msg.fileName),
                      ),
                    ));
                  });
                  _cacheService.updateMessage(
                    widget.id,
                    msg.id,
                    chatData[index],
                  );
                }
              },
              child: Text(
                imageResumeText(),
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.blue.shade400,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 根据文件名和文件夹标记返回图标。
  /// E1：分类抽至 file_icon.fileIconName（纯函数可单测），此处仅映射 IconData。
  IconData _getFileIcon(String fileName, {bool isFolder = false}) {
    switch (fileIconName(fileName, isFolder: isFolder)) {
      case 'folder':
        return Icons.folder;
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'doc':
        return Icons.description;
      case 'sheet':
        return Icons.table_chart;
      case 'slide':
        return Icons.slideshow;
      case 'image':
        return Icons.image;
      case 'video':
        return Icons.videocam;
      case 'audio':
        return Icons.audiotrack;
      case 'archive':
        return Icons.folder_zip;
      case 'apk':
        return Icons.android;
      case 'text':
        return Icons.article;
      default:
        return Icons.insert_drive_file;
    }
  }

  Widget _buildInputBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      color: const Color(0xFFF7F7F7),
      child: SafeArea(
        child: Row(
          children: [
            IconButton(
              // E1：图标判定抽至 send_dispatch.useKeyboardIcon。
              icon: Icon(
                useKeyboardIcon(isVoice: _isVoice)
                    ? Icons.keyboard
                    : Icons.mic,
                // E1：前景收敛至 media_layout.inputIconFg（宿主包 Color）。
                color: Color(inputIconFg()),
              ),
              onPressed: () {
                setState(() {
                  _isVoice = !_isVoice;
                  if (_isVoice) {
                    _focusNode.unfocus();
                    _isMore = false;
                    _emojiState = false;
                  } else {
                    _focusNode.requestFocus();
                  }
                });
              },
            ),
            Expanded(
              child: _isVoice
                  ? _buildVoiceRecordButton()
                  : Container(
                      constraints: const BoxConstraints(minHeight: 38, maxHeight: 110),
                      decoration: BoxDecoration(
                        // E1：底色收敛至 media_layout.inputFieldBg（宿主包 Color）。
                        color: Color(inputFieldBg()),
                        // 额外：新版微信化——输入框圆角胶囊
                        // E1：圆角收敛至 media_layout.inputFieldRadius。
                        borderRadius: BorderRadius.circular(inputFieldRadius()),
                      ),
                      child: TextField(
                        controller: _textController,
                        focusNode: _focusNode,
                        maxLines: null,
                        textInputAction: TextInputAction.send,
                        onSubmitted: _handleSubmittedData,
                        onChanged: (v) => setState(() {}), // E1：空刷留宿主（输入态刷新发送按钮）。
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 9,
                          ),
                        ),
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
            ),
            IconButton(
              // E1：图标判定抽至 send_dispatch.useKeyboardForPanel。
              icon: Icon(
                useKeyboardForPanel(expanded: _emojiState)
                    ? Icons.keyboard
                    : Icons.insert_emoticon,
                // E1：前景收敛至 media_layout.inputIconFg（宿主包 Color）。
                color: Color(inputIconFg()),
              ),
              onPressed: onTapEmoji,
            ),
            // E1：发送按钮可见抽至 send_dispatch.shouldShowSendButton。
            shouldShowSendButton(text: _textController.text)
                ? Padding(
                    padding: const EdgeInsets.only(right: 6.0, left: 6.0),
                    // 额外：新版微信化——圆形发送按钮
                    // E1：尺寸收敛至 media_layout.sendButtonSize。
                    child: SizedBox(
                      height: sendButtonSize(),
                      width: sendButtonSize(),
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          // E1：品牌绿/纯白收敛至 bubble_meta（宿主包 Color）。
                          backgroundColor: Color(bubbleBrandColor()),
                          foregroundColor: Color(bubbleWhite()),
                          elevation: 0,
                          padding: EdgeInsets.zero,
                          shape: const CircleBorder(),
                        ),
                        onPressed: () =>
                            _handleSubmittedData(_textController.text),
                        child: const Icon(Icons.arrow_upward, size: 20),
                      ),
                    ),
                  )
                : IconButton(
                    // E1：图标前景收敛至 media_layout.inputIconFg（宿主包 Color）。
                    icon: Icon(
                      Icons.add_circle_outline,
                      color: Color(inputIconFg()),
                    ),
                    onPressed: onTapMore,
                  ),
          ],
        ),
      ),
    );
  }

  // ========== 录音遮罩蒙层（纯视觉，触摸穿透到按钮） ==========
  Widget _buildRecordMask() {
    return Positioned.fill(
      child: IgnorePointer(
        child: Container(
          // E1：底纱收敛至 record_ui.recordMaskScrim（宿主包 Color）。
          color: Color(recordMaskScrim()),
          child: SafeArea(
            child: Column(
              children: [
                // 上滑取消区域
                Expanded(
                  flex: 3,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 70,
                          height: 70,
                          decoration: BoxDecoration(
                            // E1：圆圈底色/描边抽至 record_ui。
                            color: Color(
                              maskCircleColor(cancelling: _isCancelling),
                            ),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Color(
                                recordMaskBorderColor(
                                  cancelling: _isCancelling,
                                ),
                              ),
                              width: 4,
                            ),
                          ),
                          child: Icon(
                            // E1：图标门控抽至 recordIconIsDelete。
                            recordIconIsDelete(cancelling: _isCancelling)
                                ? Icons.delete_outline
                                : Icons.mic,
                            // E1：前景抽至 recordButtonFg。
                            color: Color(
                              recordButtonFg(cancelling: _isCancelling),
                            ),
                            size: 35,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          recordCancelHint(cancelling: _isCancelling),
                          style: TextStyle(
                            // E1：提示色抽至 recordHintColor。
                            color: Color(
                              recordHintColor(cancelling: _isCancelling),
                            ),
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _formatRecordDuration(),
                          // E1：纯白收敛至 bubble_meta.bubbleWhite（宿主包 Color）。
                          style: TextStyle(
                            color: Color(bubbleWhite()),
                            fontSize: 36,
                            fontWeight: FontWeight.w300,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // 波形图
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 50),
                  // E1：高度收敛至 record_ui.waveHeight。
                  child: SizedBox(
                    height: waveHeight(),
                    child: CustomPaint(
                      painter: _RecordingWavePainter(
                        _recordAmplitudes,
                        // E1：品牌绿收敛至 bubble_meta.bubbleBrandColor。
                        color: Color(bubbleBrandColor()),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // 松开发送区域
                Expanded(
                  flex: 2,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            // E1：发送区底色抽至 recordSendBg。
                            color: Color(
                              recordSendBg(cancelling: _isCancelling),
                            ),
                            // E1：圆角收敛至 record_ui.recordSendRadius。
                            borderRadius: BorderRadius.circular(
                              recordSendRadius(),
                            ),
                          ),
                          child: Text(
                            recordSendHint(),
                            // E1：纯白收敛至 bubble_meta.bubbleWhite（宿主包 Color）。
                            style: TextStyle(
                              color: Color(bubbleWhite()),
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ========== 语音录制按钮（使用 Listener 避免手势冲突） ==========
  Widget _buildVoiceRecordButton() {
    // 录音中显示录音状态
    if (_isRecording) {
      return Listener(
        onPointerMove: (event) {
          // 手指上滑到取消区域 → 显示取消提示
          // E1：抽至 send_waiting_texts.isInRecordCancelZone。
          final screenHeight = MediaQuery.of(context).size.height;
          setState(() {
            _isCancelling = isInRecordCancelZone(
              globalY: event.position.dy,
              screenHeight: screenHeight,
            );
          });
        },
        onPointerUp: (event) {
          if (!_isRecording) return;
          if (_isCancelling) {
            _onRecordCancel();
          } else {
            _onRecordEnd();
          }
        },
        onPointerCancel: (event) {
          // 手指被系统中断（通知栏下拉等）→ 取消录音
          if (_isRecording) {
            _onRecordCancel();
          }
        },
        child: Container(
          // E1：高度收敛至 record_ui.recordBarHeight。
          height: recordBarHeight(),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            // E1：录音条底色抽至 recordBarBg。
            color: Color(recordBarBg(cancelling: _isCancelling)),
            // E1：圆角收敛至 record_ui.recordBarRadius。
            borderRadius: BorderRadius.circular(recordBarRadius()),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 声波动画指示器
              _buildRecordingWaveIndicator(),
              const SizedBox(width: 8),
              Text(
                recordReleaseHint(cancelling: _isCancelling),
                // E1：纯白收敛至 bubble_meta.bubbleWhite（宿主包 Color，去 _isCancelling 三元）。
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Color(bubbleWhite()),
                  fontSize: 15,
                ),
              ),
              const SizedBox(width: 8),
              // 时长
              Text(
                _formatRecordDuration(),
                // E1：时长色收敛至 record_ui.recordDurationColor（宿主包 Color）。
                style: TextStyle(
                  color: Color(recordDurationColor()),
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 非录音状态：使用 Listener 处理长按
    return Listener(
      onPointerDown: (event) {
        _isRecordGestureActive = true;
        _onRecordStart();
      },
      onPointerMove: (event) {
        if (!_isRecording || !_isRecordGestureActive) return;
        // E1：抽至 send_waiting_texts.isInRecordCancelZone。
        final screenHeight = MediaQuery.of(context).size.height;
        setState(() {
          _isCancelling = isInRecordCancelZone(
            globalY: event.position.dy,
            screenHeight: screenHeight,
          );
        });
      },
      onPointerUp: (event) {
        _isRecordGestureActive = false;
        if (!_isRecording) return;
        if (_isCancelling) {
          _onRecordCancel();
        } else {
          _onRecordEnd();
        }
      },
      onPointerCancel: (event) {
        _isRecordGestureActive = false;
        if (_isRecording) {
          _onRecordCancel();
        }
      },
      child: Container(
        // E1：高度收敛至 record_ui.recordBarHeight。
        height: recordBarHeight(),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          // E1：输入框底收敛至 media_layout.inputFieldBg（宿主包 Color）。
          color: Color(inputFieldBg()),
          // E1：圆角收敛至 record_ui.recordBarRadius。
          borderRadius: BorderRadius.circular(recordBarRadius()),
          // E1：边框按原值 black12/0.5 直接构造（窄化范围，非气泡三元）。
          border: Border.all(color: const Color(0x1F000000), width: 0.5),
        ),
        child: Text(
          recordHoldHint(),
          // E1：弱文案收敛至 bubble_meta.bubbleTextDim（宿主包 Color）。
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Color(bubbleTextDim()),
          ),
        ),
      ),
    );
  }

  /// 录制中的实时波形指示器
  Widget _buildRecordingWaveIndicator() {
    // E1：尺寸收敛至 record_ui.recordIndicatorW/H。
    return SizedBox(
      width: recordIndicatorW(),
      height: recordIndicatorH(),
      child: CustomPaint(painter: _RecordingWavePainter(_recordAmplitudes)),
    );
  }

  /// 格式化录音时长（E1：逻辑抽至 audio_format）。
  String _formatRecordDuration() => formatRecordDuration(_recordDurationMs);

  // ========== 录音控制 ==========

  Future<void> _onRecordStart() async {
    // 防止重复进入
    if (_isRecording) return;

    final hasPerm = await _audioService.hasPermission();
    if (!hasPerm) {
      _isRecordGestureActive = false;
      if (mounted) {
        showCenterToast(context, recordPermText());
      }
      return;
    }

    final path = await _audioService.startRecording();
    if (path == null) {
      _isRecordGestureActive = false;
      if (mounted) {
        showCenterToast(context, recordStartFailText());
      }
      return;
    }

    setState(() {
      _isRecording = true;
      _showRecordMask = true;
      _isCancelling = false;
      _recordDurationMs = 0;
      _recordAmplitudes.clear();
      _recordWaveformSamples.clear();
    });

    // 每 100ms 更新录音时长
    // E1：步长/上限抽至 record_policy（纯函数可单测）。
    _recordTimer = Timer.periodic(
        recordTick() /* E1：延时收敛至 delay_policy */, (timer) {
      if (!_isRecording) {
        timer.cancel();
        return;
      }
      if (mounted) {
        setState(() {
          _recordDurationMs = nextRecordDuration(_recordDurationMs);
        });
        // 最长录制 60 秒
        if (shouldAutoStopRecord(_recordDurationMs)) {
          _onRecordEnd();
        }
      }
    });

    // 监听振幅变化（实时波形）
    // E1：上限抽至 record_policy.exceedsSampleCap/exceedsUiAmpCap。
    _recordStateSub = _audioService.amplitudeStream.listen((amp) {
      if (!mounted || !_isRecording) return;
      _recordWaveformSamples.add(amp);
      if (exceedsSampleCap(_recordWaveformSamples.length)) {
        _recordWaveformSamples.removeAt(0);
      }
      setState(() {
        _recordAmplitudes.add(amp);
        if (exceedsUiAmpCap(_recordAmplitudes.length)) {
          _recordAmplitudes.removeAt(0);
        }
      });
    });
  }

  Future<void> _onRecordEnd() async {
    if (!_isRecording) return;

    _recordTimer?.cancel();
    _recordStateSub?.cancel();

    final durationMs = _recordDurationMs;
    setState(() {
      _isRecording = false;
      _showRecordMask = false;
      _isCancelling = false;
      _isRecordGestureActive = false;
    });

    final amps = List<double>.from(_recordWaveformSamples);
    final result = await _audioService.stopRecording(durationMs: durationMs);

    if (result == null ||
        // E1：抽至 send_waiting_texts.isTooShortRecord（判空后收窄，无需 ?.）。
        isTooShortRecord(durationMs: result.durationMs)) {
      // 录音时长不足 0.5 秒，提示太短并删除文件
      if (result != null) {
        try {
          await File(result.path).delete();
        } catch (_) {}
      }
      if (mounted) {
        // E1：文案抽至 send_waiting_texts.recordTooShortText。
        showCenterToast(context, recordTooShortText());
      }
      return;
    }

    // 发送音频消息（统一入口带在线检查）；波形用真实振幅采样
    await _trySend(
      type: SendActionType.audio,
      recordResult: result,
      text: _encodeWaveformFromAmps(amps),
    );
  }

  Future<void> _onRecordCancel() async {
    if (!_isRecording) return;

    _recordTimer?.cancel();
    _recordStateSub?.cancel();

    setState(() {
      _isRecording = false;
      _showRecordMask = false;
      _isCancelling = false;
      _isRecordGestureActive = false;
    });

    await _audioService.cancelRecording();
  }

  /// 发送音频消息（v2：语音 = 单文件会话，fileMeta 旁路随 _sendViaLs 发送）
  Future<void> _sendAudioMessage(
    RecordResult result, {
    String? waveformData,
  }) async {
    // E1：命名抽至 send_naming.buildAudioFileName/buildAudioMsgId。
    final nowMsTick = nowMs() /* E1：时钟收敛至 app_clock.nowMs；改名避让顶层 nowMs() */;
    final fileName = buildAudioFileName(nowMsTick);
    final fileSize = result.fileSize;
    final durationMs = result.durationMs;

    // P1-7：使用录制期间真实振幅；无采样时仅为旧环境回退
    // E1：波形回退抽至 TransferTexts.resolveAudioWaveform（已有值保留）。
    waveformData = TransferTexts.resolveAudioWaveform(
      existing: waveformData,
      fallback: _encodeWaveformFromAmps(const []),
    );
    final msgId = buildAudioMsgId(nowMsTick);

    // 先创建本地语音气泡，状态为 pending（v2 握手 ID 仅作模型兼容字段）
    // E1：构造抽至 message_factory.buildOutgoingAudio，标签抽至 audioLabel。
    final audioMsg = buildOutgoingAudio(
      msgId: msgId,
      fileName: fileName,
      fileSizeText: formatFileSize(fileSize),
      filePath: result.path,
      content: audioLabel(),
      transferId: _ids.newTransferId(),
      durationMs: durationMs,
      waveformData: waveformData,
      now: now() /* E1：时钟收敛至 app_clock.now */,
    );

    setState(() {
      chatData = appendMessage(chatData, audioMsg);
    });
    _cacheService.appendMessage(widget.id, audioMsg);
    _scrollToBottom();

    // P0-3 对应 v2：预计算语音哈希（上传 422 重试依赖）
    String? audioSha256;
    try {
      audioSha256 = await lsSha256OfFile(result.path);
    } catch (e) {
      // E1：语音SHA日志收敛至 chat_debug_logs.audioShaFailLog。
      debugPrint(audioShaFailLog(e));
    }

    // v2：复用通用发送管线（进度/完成/失败回写气泡，语音 content 保持 🎙️ 标签）
    await _sendViaLs([
      _LsSendItem(
        msgId: msgId,
        filePath: result.path,
        fileName: fileName,
        fileSize: fileSize,
        sha256: audioSha256,
        isImage: false,
        isFolder: false,
        isVoice: true,
        durationMs: durationMs,
        waveformData: waveformData,
        errLabel: sendErrLabel(isFolder: false),
        displayName: fileName,
      ),
    ]);
  }

  /// P1-7：将录音期间采集的真实振幅降采样为固定数量波形柱
  /// （E1：逻辑抽至 audio_format，复用 ProtocolCodec.downsampleWaveform）。
  /// E1：抽至 transfer_limits.kWaveformBars。
  String _encodeWaveformFromAmps(List<double> amps, {int bars = kWaveformBars}) =>
      encodeWaveformFromAmps(amps, bars: bars);

  Widget _buildEmojiWidget() {
    // E1：网格/边距/字号收敛至 emojiGridParams。
    final gp = emojiGridParams();
    return GridView.builder(
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: gp.maxExtent,
        mainAxisSpacing: gp.mainSpacing,
        crossAxisSpacing: gp.crossSpacing,
        childAspectRatio: 1.0,
      ),
      padding: EdgeInsets.all(gp.padding),
      itemCount: _emojiList.length,
      itemBuilder: (BuildContext context, int index) {
        final String mockEmoji = _emojiList[index];
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => insertText(mockEmoji),
          child: Center(
            child: Text(mockEmoji, style: TextStyle(fontSize: gp.fontSize)),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    // 注销接收/取消 hook（双键：设备 id + 对端指纹），避免悬空回调持有已销毁的 State
    ChatPage.incomingFileHooks.remove(widget.id);
    ChatPage.cancelSendHooks.remove(widget.id);
    final hookFp = _peerFingerprint;
    if (isNotNull(hookFp)) {
      ChatPage.incomingFileHooks.remove(requireNonNullHint(hookFp));
      ChatPage.cancelSendHooks.remove(requireNonNullHint(hookFp));
    }
    WidgetsBinding.instance.removeObserver(this);
    _focusNode.removeListener(_onFocusChanged);
    _msgSubscription?.cancel();
    // v2：页面销毁即取消所有进行中的发送会话（abort 挂起的 prepare/upload）
    for (final token in _lsCancelByMsgId.values) {
      token.cancel();
    }
    _lsCancelByMsgId.clear();
    _lsSessionByMsgId.clear();
    // TCP 服务器由 ChatListPage 全局管理，不在此 dispose
    // 清理录音资源
    _recordTimer?.cancel();
    _recordStateSub?.cancel();
    _audioService.stop();
    // 清理所有待确认的 ACK 定时器
    for (final timer in _pendingAcks.values) {
      timer.cancel();
    }
    _pendingAcks.clear();
    _textQueue.clear();
    _recentRecvMsgIds.clear();
    _retryCount.clear();
    // 清理 OverlayEntry，防止内存泄漏
    _actionBubbleEntry?.remove();
    _actionBubbleEntry = null;
    // 清理缓存，释放内存
    _imgCache.clear();
    _lastProgressTick.clear();
    _retryCount.clear();
    _textController.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 构建精选常用 emoji 列表，跳过 Unicode 未分配的空白区间
  static List<String> _buildEmojiList() => buildEmojiList();
}

/// 录制中的实时波形绘制器
class _RecordingWavePainter extends CustomPainter {
  final List<double> amplitudes;
  final Color color;
  _RecordingWavePainter(this.amplitudes, {this.color = Colors.white});

  @override
  void paint(Canvas canvas, Size size) {
    // E1：波形有效判定抽至 audio_format.hasWaveform。
    if (!hasWaveform(amplitudes)) return;

    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2;

    // E1：单柱几何抽至 audio_format.waveBarGeometry（纯函数可单测）。
    for (int i = 0; i < amplitudes.length; i++) {
      final g = waveBarGeometry(
        index: i,
        count: amplitudes.length,
        amplitude: amplitudes[i],
        width: size.width,
        height: size.height,
      );

      canvas.drawLine(Offset(g.x, g.y), Offset(g.x, g.y + g.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RecordingWavePainter oldDelegate) =>
      oldDelegate.amplitudes != amplitudes || oldDelegate.color != color;
}

/// 全屏图片查看器
class _ImageViewerPage extends StatelessWidget {
  final String imagePath;
  final String title;

  const _ImageViewerPage({required this.imagePath, required this.title});

  @override
  Widget build(BuildContext context) {
    final file = File(imagePath);
    final fileExists = file.existsSync();
    // E1：预览门控/缩放收敛至 media_layout（行为不变）。
    final scale = viewerScaleRange();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        elevation: 0,
      ),
      body: Center(
        // E1：预览门控抽至 shouldShowViewer。
        child: shouldShowViewer(exists: fileExists)
            ? InteractiveViewer(
                minScale: scale.min,
                maxScale: scale.max,
                child: Image.file(
                  file,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) {
                    return _buildErrorWidget();
                  },
                ),
              )
            : _buildErrorWidget(),
      ),
    );
  }

  Widget _buildErrorWidget() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.image_not_supported_outlined,
          size: 80,
          color: Colors.grey[600],
        ),
        const SizedBox(height: 16),
        Text(
          imageViewerMissingText(),
          style: TextStyle(fontSize: 16, color: Colors.grey[500]),
        ),
      ],
    );
  }
}

// 消息长按动作气泡背景画笔：圆角矩形 + 三角箭头合为一个连续形状
class _ActionBubblePainter extends CustomPainter {
  final double arrowX; // 箭头尖端 X（相对 widget）
  final bool arrowOnTop; // true=箭头在顶部朝上 ▲，false=箭头在底部朝下 ▼
  final Color color;
  final double radius;
  final double arrowW;
  final double arrowH;

  _ActionBubblePainter({
    required this.arrowX,
    required this.arrowOnTop,
    required this.color,
    required this.radius,
    required this.arrowW,
    required this.arrowH,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final path = Path();

    // 圆角矩形（气泡主体）
    // E1：几何抽至 action_bubble_layout（纯函数可单测），此处仅薄委托。
    final rectTop = bubbleRectTop(arrowOnTop: arrowOnTop, arrowH: arrowH);
    final bubbleH = bubbleBodyHeight(height: size.height, arrowH: arrowH);
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, rectTop, size.width, bubbleH),
      Radius.circular(radius),
    );
    path.addRRect(rrect);

    // 三角箭头（与矩形用同一颜色，无缝衔接）
    final tri = arrowTriangle(
      arrowOnTop: arrowOnTop,
      centerX: arrowX,
      arrowW: arrowW,
      arrowH: arrowH,
      height: size.height,
    );
    path.moveTo(tri[0].x, tri[0].y);
    path.lineTo(tri[1].x, tri[1].y);
    path.lineTo(tri[2].x, tri[2].y);
    path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_ActionBubblePainter old) => shouldRepaintBubble(
        arrowX: arrowX,
        arrowOnTop: arrowOnTop,
        oldArrowX: old.arrowX,
        oldArrowOnTop: old.arrowOnTop,
      );
}
