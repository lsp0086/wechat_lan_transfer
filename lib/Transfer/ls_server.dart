// LocalSend Protocol v2 接收端 HTTPS 服务。
// 对齐官方 packages/core/src/http/server/v2.rs：
// - 单会话槽：pending（等用户决策）→ active（逐文件上传）；占用中新请求 409
// - prepare-upload 请求挂起直到 UI 决策（接收方主导节奏，无固定超时）
//   发送方断开 → response.done 触发 pending 清理（对齐官方 PendingSessionGuard）
// - upload 校验 sessionId/fileId/token + 发送方 IP；流式落盘 .part → 改名 + sha256
// - cancel：pending/active 会话按发送方 IP 取消；未知会话回传 CancelReceived
//   （对端在取消"我们正在发送"的会话）
// - PIN：query ?pin= 明文比对，per-IP 3 次失败 → 429

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:wechat_lan_transfer/Services/session_tracker.dart';
import 'package:wechat_lan_transfer/Services/tls_identity_service.dart';
import 'package:wechat_lan_transfer/Transfer/file_utils.dart';
import 'package:wechat_lan_transfer/Transfer/ls_dto.dart';

const _uuid = Uuid();

/// 每文件上传尝试上限（对齐官方 MAX_UPLOAD_ATTEMPTS）。
const int kLsMaxUploadAttempts = 3;

/// PIN 失败限流上限（per-IP，对齐官方 MAX_PIN_ATTEMPTS）。
const int kLsMaxPinAttempts = 3;

/// active 会话无上传活动的自动过期（防发送方失联后槽位泄漏）。
const int kLsActiveIdleSec = 600;

/// 接收方对 prepare-upload 的决策。
sealed class LsPrepareDecision {
  const LsPrepareDecision();
}

/// 接受（文件 ID 集合，空集回 204）。
class LsAccept extends LsPrepareDecision {
  final Set<String> fileIds;
  const LsAccept(this.fileIds);
}

/// 拒绝（403）。
class LsDecline extends LsPrepareDecision {
  const LsDecline();
}

/// 入站 prepare-upload 请求快照（UI 弹窗/自动接收用）。
class LsIncomingRequest {
  final String sessionId;
  final String senderIp;
  final LsDeviceDto sender;
  /// TLS 层验证的对端证书指纹（不可伪造）；对端未带证书时为 null。
  final String? certFingerprint;
  final Map<String, LsFileDto> files;

  const LsIncomingRequest({
    required this.sessionId,
    required this.senderIp,
    required this.sender,
    this.certFingerprint,
    required this.files,
  });

  /// 可信指纹：优先 TLS 层，回退 info.fingerprint（自报，TOFU）。
  String get trustedFingerprint =>
      (certFingerprint ?? sender.fingerprint).toLowerCase();
}

/// 文件级传输结果事件。
class LsFileResult {
  final String sessionId;
  final String fileId;
  final bool success;
  final String? savedPath;
  final String? error;

  const LsFileResult({
    required this.sessionId,
    required this.fileId,
    required this.success,
    this.savedPath,
    this.error,
  });
}

enum LsSessionEndReason { finished, cancelled, aborted }

/// 单个文件的会话内状态。
class _SessionFile {
  final LsFileDto dto;
  final String token;
  String status; // pending | inProgress | finished | failed
  int attempts = 0;
  _SessionFile(this.dto, this.token) : status = 'pending';
}

class _PendingSession {
  final String sessionId;
  final String senderIp;
  final void Function() declineBySender; // 发送方 /cancel：决策以拒绝完成（回复 403）
  _PendingSession(this.sessionId, this.senderIp, this.declineBySender);
}

class _ActiveSession {
  final String sessionId;
  final String senderIp;
  final Map<String, _SessionFile> files;
  final LsDeviceDto sender;
  DateTime lastActivity = DateTime.now();
  _ActiveSession(this.sessionId, this.senderIp, this.files, this.sender);
}

/// v2 HTTPS 服务端（端口 53317，自签证书）。
/// 注意：不开启 requestClientCertificate —— dart:io 服务端会强校验客户端
/// 证书链（对端自签证书必然不在系统信任库 → 握手直接被掐断，连回环都过不了）。
/// 对端身份按 TOFU + info.fingerprint（自报）+ 传输期客户端指纹钉扎保证。
class LsServer {
  HttpServer? _server;
  _PendingSession? _pending;
  _ActiveSession? _active;
  Timer? _idleTimer;

  final LsStorage _storage = LsStorage();
  void setSaveDirectory(String path) => _storage.setSaveDirectory(path);

  bool get isRunning => _server != null;
  int _boundPort = kLsDefaultPort;
  int get boundPort => _boundPort;

  // ===== UI 绑定的回调 =====

  /// prepare-upload 到达：UI 决策（弹窗/自动接收）。返回的 Future 在用户
  /// 决策前保持未完成 —— 这正是"请求挂起等用户"的机制。
  Future<LsPrepareDecision> Function(LsIncomingRequest request)?
      onPrepareUpload;

  /// 收到未知会话的 cancel：对端在取消"我们正在发送"的会话。
  void Function(String ip, String sessionId)? onCancelReceived;

  /// 单文件落盘完成/失败。
  void Function(LsFileResult result)? onFileResult;

  /// 文件进度（未节流，UI 侧节流）。
  void Function(String sessionId, String fileId, int received, int total)?
      onFileProgress;

  /// 会话结束：finished=全部到终态；cancelled=发送方主动取消；aborted=发送方断开。
  void Function(String sessionId, LsSessionEndReason reason)? onSessionEnd;

  /// 收到 register（对端发现本端并登记）：携带对端设备信息与来源 IP。
  /// 反向发现通路：iOS 无组播 entitlement 收不到组播/受限广播 announce，
  /// 仅能凭此得知「对端已发现本端」（官方 register 语义即登记到对端）。
  void Function(LsDeviceDto peer, String senderIp)? onRegisterReceived;

  /// 本端设备信息（alias/fingerprint/port）。
  LsDeviceDto Function()? selfInfo;

  /// 接收 PIN 读取器（AppConfigStore 注入，便于测试）。
  Future<String> Function()? receivePinProvider;

  // ===== 生命周期 =====

  /// 启动（幂等）。[preferredPort] 起连续探测 10 个端口（占用即下移）。
  /// 优先双栈 IPv6（v4-mapped），无 IPv6 环境回退纯 IPv4。
  /// [tlsContext]/[saveDir] 测试注入用；生产留空走 TlsIdentityService/默认目录。
  Future<void> start({
    int? preferredPort,
    SecurityContext? tlsContext,
    String? saveDir,
  }) async {
    if (_server != null) return;
    SecurityContext? ctx = tlsContext;
    if (ctx == null) {
      await TlsIdentityService.instance.init();
      ctx = TlsIdentityService.instance.serverContext;
    }
    if (ctx == null) {
      throw Exception('本端 TLS 证书不可用，无法启动 v2 接收服务');
    }
    if (saveDir != null) _storage.setSaveDirectory(saveDir);
    final dir = _storage.saveDirectory ?? await _storage.ensureSaveDir();
    debugPrint('[LsServer] 启动中: TLS上下文就绪, 保存目录 $dir');
    try {
      await lsCleanupPartialFiles(dir);
    } catch (e) {
      // 清理残留只是尽力而为，不能阻断服务启动
      debugPrint('[LsServer] 清理残留 .part 失败（忽略）: $e');
    }

    final prefer = preferredPort ?? kLsDefaultPort;
    Object? lastError;
    for (var port = prefer; port < prefer + 10; port++) {
      try {
        _server = await HttpServer.bindSecure(
          InternetAddress.anyIPv6,
          port,
          ctx,
          v6Only: false,
        );
        _boundPort = port;
        break;
      } on SocketException catch (e) {
        lastError = e;
        debugPrint('[LsServer] 绑定 v6 :$port 失败: $e');
        // 无 IPv6 时回退纯 v4 再试同一端口
        try {
          _server = await HttpServer.bindSecure(
            InternetAddress.anyIPv4,
            port,
            ctx,
          );
          _boundPort = port;
          break;
        } on SocketException catch (e2) {
          lastError = e2;
          debugPrint('[LsServer] 绑定 v4 :$port 失败: $e2');
        }
      } catch (e) {
        lastError = e;
        debugPrint('[LsServer] 绑定 :$port 异常: $e');
      }
    }
    if (_server == null) {
      throw Exception('v2 服务绑定端口失败（$prefer..${prefer + 9}）: $lastError');
    }

    _server!.listen(
      _handleRequest,
      onError: (Object e) => debugPrint('[LsServer] 监听异常: $e'),
      cancelOnError: false,
    );
    debugPrint('[LsServer] v2 HTTPS 已启动: 端口 $_boundPort，保存路径 $dir');
  }

  void stop() {
    _idleTimer?.cancel();
    _server?.close(force: true);
    _server = null;
    _pending = null;
    _active = null;
  }

  // ===== 请求路由 =====

  Future<void> _handleRequest(HttpRequest req) async {
    final peerIp = normalizeIp(req.connectionInfo?.remoteAddress);
    debugPrint('[LsServer] <- ${req.method} ${req.uri.path} from $peerIp');
    try {
      final path = req.uri.path;
      final method = req.method;
      if (path == '/api/localsend/v2/prepare-upload' && method == 'POST') {
        await _prepareUpload(req);
      } else if (path == '/api/localsend/v2/upload' && method == 'POST') {
        await _upload(req);
      } else if (path == '/api/localsend/v2/cancel' && method == 'POST') {
        await _cancel(req);
      } else if (path == '/api/localsend/v2/info' && method == 'GET') {
        await _replyJson(
            req, 200, (selfInfo?.call() ?? _fallbackSelf).toJson());
      } else if (path == '/api/localsend/v2/register' && method == 'POST') {
        await _register(req, peerIp);
      } else {
        await _replyJson(req, 404, {'message': 'Not found'});
      }
    } catch (e, st) {
      debugPrint('[LsServer] 处理异常: $e\n$st');
      try {
        await _replyJson(req, 500, {'message': 'Internal error'});
      } catch (_) {}
    }
  }

  LsDeviceDto get _fallbackSelf => LsDeviceDto(
        alias: 'WeChatLanTransfer',
        fingerprint: TlsIdentityService.instance.fingerprint,
        port: _boundPort,
      );

  /// POST /register：读请求体取对端设备信息，上报反向发现；响应体结构
  /// 对齐官方 RegisterResponseDtoV2（无 port/protocol 字段）。
  /// register 是尽力而为：body 解析失败不影响 200 响应。
  Future<void> _register(HttpRequest req, String senderIp) async {
    try {
      final raw = await utf8.decoder.bind(req).join();
      final body = jsonDecode(raw);
      if (body is Map<String, dynamic>) {
        final peer = LsDeviceDto.fromJson(body);
        if (peer.fingerprint.trim().isNotEmpty && senderIp.isNotEmpty) {
          onRegisterReceived?.call(peer, senderIp);
        }
      }
    } catch (e) {
      debugPrint('[LsServer] register body 解析失败（忽略）: $e');
    }
    final self = selfInfo?.call() ?? _fallbackSelf;
    await _replyJson(req, 200, {
      'alias': self.alias,
      'version': self.version,
      if (self.deviceModel != null) 'deviceModel': self.deviceModel,
      if (self.deviceType != null) 'deviceType': self.deviceType,
      'fingerprint': self.fingerprint,
      'download': self.download,
    });
  }

  // ===== PIN 校验（per-IP 限流） =====

  final PinFailLimiter _pinFails = PinFailLimiter(maxFails: kLsMaxPinAttempts);

  Future<bool> _checkPin(HttpRequest req) async {
    final provider = receivePinProvider;
    final required = (await provider?.call() ?? '').trim();
    if (required.isEmpty) return true;
    final ip = normalizeIp(req.connectionInfo?.remoteAddress);
    final given = req.uri.queryParameters['pin'] ?? '';
    if (given != required) {
      // 对齐官方语义：先自增失败计数再判限流（第 4 次失败即 429）
      final fails = _pinFails.noteFailure(ip);
      if (fails > kLsMaxPinAttempts) {
        await _replyJson(req, 429, {'message': 'Too many requests'});
        return false;
      }
      await _replyJson(req, 401, {'message': 'Invalid pin'});
      return false;
    }
    _pinFails.reset(ip);
    return true;
  }

  // ===== prepare-upload =====

  Future<void> _prepareUpload(HttpRequest req) async {
    // 先读完请求体再校验 PIN：错误路径若带着未读 body 复用 keep-alive
    // 连接，残留字节会被解析成下一个请求（管线错位）。
    final raw = await utf8.decoder.bind(req).join();
    if (!await _checkPin(req)) return;

    Map<String, dynamic> body;
    try {
      body = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      await _replyJson(req, 400, {'message': 'Invalid body'});
      return;
    }
    final infoJson = body['info'];
    final filesJson = body['files'];
    if (infoJson is! Map || filesJson is! Map || filesJson.isEmpty) {
      await _replyJson(req, 400, {'message': 'Invalid body'});
      return;
    }
    final info = LsDeviceDto.fromJson(infoJson.cast<String, dynamic>());
    final files = <String, LsFileDto>{};
    for (final entry in filesJson.entries) {
      files['${entry.key}'] = LsFileDto.fromJson(
        (entry.value as Map).cast<String, dynamic>(),
      );
    }

    final senderIp = normalizeIp(req.connectionInfo?.remoteAddress);
    // 注意：dart:io 的 HttpConnectionInfo 不暴露对端证书（已知能力缺口），
    // 服务端无法做证书级指纹校验。对端身份以 info.fingerprint（自报，TOFU）
    // + 会话绑定 IP + 一次性 token 保证；发送方向的反向钉扎在 LsClient
    // badCertificateCallback 中完成（不受此限制）。
    final String? certFp = null;

    // 单会话槽：占用即 409（对齐官方）
    if (_pending != null || _active != null) {
      debugPrint('[LsServer] prepare-upload 409（会话槽占用: '
          'pending=${_pending != null} active=${_active != null}）');
      await _replyJson(req, 409, {'message': 'Blocked by another session'});
      return;
    }

    final sessionId = _uuid.v4();
    final decisionCh = Completer<LsPrepareDecision>();
    final senderGone = Completer<void>();
    _pending = _PendingSession(sessionId, senderIp, () {
      // 发送方主动 /cancel：以 LsDecline 完成决策 → prepare-upload 回 403
      //（对齐官方：发送方收到 403 Rejected，而非连接被静默关闭）
      if (!decisionCh.isCompleted) decisionCh.complete(const LsDecline());
    });

    final request = LsIncomingRequest(
      sessionId: sessionId,
      senderIp: senderIp,
      sender: info,
      certFingerprint: certFp,
      files: files,
    );

    // UI 决策（回调返回的 Future 未完成 = 请求挂起等用户）
    final handler = onPrepareUpload;
    if (handler != null) {
      () async {
        try {
          final d = await handler(request);
          if (!decisionCh.isCompleted) decisionCh.complete(d);
        } catch (e) {
          debugPrint('[LsServer] onPrepareUpload 回调异常: $e');
          if (!decisionCh.isCompleted) decisionCh.complete(const LsDecline());
        }
      }();
    } else {
      decisionCh.complete(const LsDecline());
    }

    // 断开感知：dart:io 的 response.done 在未写出任何响应字节时不会因对端
    // 断开而完成（实测确认，TLS/明文皆然）。挂起阶段改用 detachSocket 接管
    // 底层 socket —— 对端 abort/断网时 socket.done 即刻触发。
    final socket = await req.response.detachSocket(writeHeaders: false);
    socket.listen(
      (_) {}, // 决策前发送方不应再发数据；忽略
      onDone: () {
        if (!senderGone.isCompleted) senderGone.complete();
      },
      onError: (Object _) {
        if (!senderGone.isCompleted) senderGone.complete();
      },
    );

    // 决策与"发送方断开"竞速：断开时 decisionCh 可能永远不完成，
    // 不能只等 decisionCh（否则挂起的 handler 泄漏）。
    final outcome =
        await Future.any<Object?>([decisionCh.future, senderGone.future]);

    if (!decisionCh.isCompleted) {
      // 发送方已断开：释放槽位，通知 UI 清理 pending 气泡
      debugPrint('[LsServer] prepare-upload 发送方断开（aborted）: $sessionId');
      _pending = null;
      onSessionEnd?.call(sessionId, LsSessionEndReason.aborted);
      socket.destroy();
      return;
    }
    final decision = outcome as LsPrepareDecision;

    final acceptedIds = switch (decision) {
      LsAccept(:final fileIds) => files.keys.where(fileIds.contains).toSet(),
      LsDecline() => null,
    };

    if (acceptedIds == null) {
      debugPrint('[LsServer] prepare-upload 被拒绝（403）: $sessionId');
      _pending = null;
      await _replyRaw(socket, 403, 'Forbidden', {'message': 'Rejected'});
      return;
    }
    if (acceptedIds.isEmpty) {
      debugPrint('[LsServer] prepare-upload 空集接受（204）: $sessionId');
      _pending = null;
      await _replyRaw(socket, 204, 'No Content', null);
      return;
    }

    // 转 active，逐文件生成 token
    final activeFiles = <String, _SessionFile>{
      for (final id in acceptedIds) id: _SessionFile(files[id]!, _uuid.v4()),
    };
    _pending = null;
    _active = _ActiveSession(sessionId, senderIp, activeFiles, info);
    _startIdleWatchdog(sessionId);

    debugPrint(
        '[LsServer] 上传会话已建立: $sessionId（${activeFiles.length} 文件）');
    await _replyRaw(socket, 200, 'OK', {
      'sessionId': sessionId,
      'files': {for (final e in activeFiles.entries) e.key: e.value.token},
    });
  }

  /// active 会话空闲看门狗：发送方接受后失联，自动释放槽位。
  void _startIdleWatchdog(String sessionId) {
    _idleTimer?.cancel();
    _idleTimer = Timer.periodic(const Duration(seconds: 30), (t) {
      final session = _active;
      if (session == null || session.sessionId != sessionId) {
        t.cancel();
        return;
      }
      if (DateTime.now().difference(session.lastActivity).inSeconds >=
          kLsActiveIdleSec) {
        t.cancel();
        debugPrint('[LsServer] 会话空闲超时释放: $sessionId');
        _active = null;
        onSessionEnd?.call(sessionId, LsSessionEndReason.aborted);
      }
    });
  }

  // ===== upload =====

  Future<void> _upload(HttpRequest req) async {
    // 上传响应一律不带 keep-alive：错误路径不消费请求体（可能是大文件流），
    // 复用连接会导致管线错位；上传本就走独立新连接。
    req.response.persistentConnection = false;
    final q = req.uri.queryParameters;
    final sessionId = q['sessionId'];
    final fileId = q['fileId'];
    final token = q['token'];
    if (sessionId == null || fileId == null || token == null) {
      await _replyJson(req, 400, {'message': 'Missing parameters'});
      return;
    }

    final session = _active;
    final senderIp = normalizeIp(req.connectionInfo?.remoteAddress);
    if (session == null ||
        session.sessionId != sessionId ||
        session.senderIp != senderIp) {
      await _replyJson(req, 403, {'message': 'Invalid token or IP address'});
      return;
    }
    final file = session.files[fileId];
    if (file == null || file.token != token || file.status != 'pending') {
      await _replyJson(req, 403, {'message': 'Invalid token or IP address'});
      return;
    }
    file.status = 'inProgress';
    file.attempts++;
    session.lastActivity = DateTime.now();

    // 落盘：先解析最终路径（冲突命名），写 .part，完成后改名+校验
    String savePath;
    File part;
    try {
      savePath = await _storage
          .resolveSavePath(lsSanitizeFileName(file.dto.fileName));
      part = File('$savePath.part');
    } catch (e) {
      file.status = 'failed';
      onFileResult?.call(LsFileResult(
        sessionId: sessionId,
        fileId: fileId,
        success: false,
        error: '解析保存路径失败: $e',
      ));
      await _replyJson(req, 500, {'message': 'Internal error'});
      return;
    }

    final total = file.dto.size;
    var received = 0;
    var streamError = false;
    IOSink? sink;
    try {
      sink = part.openWrite();
      await for (final chunk in req) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          session.lastActivity = DateTime.now();
          onFileProgress?.call(sessionId, fileId, received, total);
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
    } catch (e) {
      streamError = true;
      debugPrint('[LsServer] 接收中断: $fileId ($e)');
    }

    if (streamError) {
      // 发送方中途断开：删半文件，标记失败
      file.status = 'failed';
      try {
        if (sink != null) await sink.close();
        if (await part.exists()) await part.delete();
      } catch (_) {}
      onFileResult?.call(LsFileResult(
        sessionId: sessionId,
        fileId: fileId,
        success: false,
        error: '发送方中断',
      ));
      _finalizeSession(sessionId);
      return;
    }

    // SHA-256 校验（可选字段；官方语义：422 + 同 token 重试 ≤3）
    if (file.dto.sha256 != null && file.dto.sha256!.isNotEmpty) {
      final actual = await lsSha256OfFile(part.path);
      if (actual != file.dto.sha256!.toLowerCase()) {
        try {
          await part.delete();
        } catch (_) {}
        if (file.attempts < kLsMaxUploadAttempts) {
          file.status = 'pending'; // 允许同 token 重传
          await _replyJson(req, 422, {'message': 'Checksum mismatch'});
          return;
        }
        file.status = 'failed';
        onFileResult?.call(LsFileResult(
          sessionId: sessionId,
          fileId: fileId,
          success: false,
          error: '校验失败',
        ));
        _finalizeSession(sessionId);
        await _replyJson(req, 422, {'message': 'Checksum mismatch'});
        return;
      }
    }

    try {
      await part.rename(savePath);
    } catch (e) {
      file.status = 'failed';
      try {
        await part.delete();
      } catch (_) {}
      onFileResult?.call(LsFileResult(
        sessionId: sessionId,
        fileId: fileId,
        success: false,
        error: '落盘失败: $e',
      ));
      _finalizeSession(sessionId);
      await _replyJson(req, 500, {'message': 'Internal error'});
      return;
    }

    file.status = 'finished';
    onFileResult?.call(LsFileResult(
      sessionId: sessionId,
      fileId: fileId,
      success: true,
      savedPath: savePath,
    ));
    await req.response.close();
    _finalizeSession(sessionId);
  }

  /// 全部文件到终态后结束会话并释放槽位。
  void _finalizeSession(String sessionId) {
    final session = _active;
    if (session == null || session.sessionId != sessionId) return;
    final allDone = session.files.values
        .every((f) => f.status == 'finished' || f.status == 'failed');
    if (!allDone) return;
    _active = null;
    _idleTimer?.cancel();
    onSessionEnd?.call(sessionId, LsSessionEndReason.finished);
  }

  // ===== cancel =====

  Future<void> _cancel(HttpRequest req) async {
    final sessionId = req.uri.queryParameters['sessionId'];
    final ip = normalizeIp(req.connectionInfo?.remoteAddress);

    // pending：发送方还不知道 sessionId（响应里才有），同 IP 即可取消
    final pending = _pending;
    if (pending != null &&
        pending.senderIp == ip &&
        (sessionId == null || sessionId == pending.sessionId)) {
      pending.declineBySender();
      _pending = null;
      onSessionEnd?.call(pending.sessionId, LsSessionEndReason.cancelled);
      await req.response.close();
      return;
    }

    // active：同 sessionId + 同 IP 取消
    final active = _active;
    if (sessionId != null &&
        active != null &&
        active.sessionId == sessionId &&
        active.senderIp == ip) {
      _active = null;
      _idleTimer?.cancel();
      active.files.forEach((fileId, f) {
        if (f.status != 'finished') {
          f.status = 'failed';
          onFileResult?.call(LsFileResult(
            sessionId: sessionId,
            fileId: fileId,
            success: false,
            error: '对端已取消',
          ));
        }
      });
      onSessionEnd?.call(sessionId, LsSessionEndReason.cancelled);
      await req.response.close();
      return;
    }

    // 不是本端的接收会话：对端在取消"我们正在发送"的会话
    if (sessionId != null) {
      onCancelReceived?.call(ip, sessionId);
    }
    await req.response.close();
  }

  // ===== 工具 =====

  Future<void> _replyJson(HttpRequest req, int status, Object? body) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(body == null ? '' : jsonEncode(body));
    await req.response.close();
  }

  /// 通过 detachSocket 接管的 socket 手写 HTTP/1.1 响应（挂起决策的回复）。
  /// 带 Connection: close：上传走新连接，服务端按发送方 IP + token 校验。
  Future<void> _replyRaw(
      Socket socket, int status, String reason, Object? body) async {
    try {
      if (body == null) {
        // 204 等无体响应：不允许带 Content-Length
        socket.add(utf8.encode(
          'HTTP/1.1 $status $reason\r\nConnection: close\r\n\r\n',
        ));
      } else {
        final bytes = utf8.encode(jsonEncode(body));
        socket.add(utf8.encode(
          'HTTP/1.1 $status $reason\r\n'
          'Content-Type: application/json\r\n'
          'Content-Length: ${bytes.length}\r\n'
          'Connection: close\r\n\r\n',
        ));
        socket.add(bytes);
      }
      await socket.flush();
    } catch (_) {}
    socket.destroy();
  }
}

/// 归一化对端地址：IPv4-mapped IPv6（::ffff:a.b.c.d）→ IPv4。
/// `::`（双栈通配兜底）返回空串，调用方按会话绑定判定失败即拒。
String normalizeIp(InternetAddress? addr) {
  if (addr == null) return '';
  var host = addr.address;
  if (host.startsWith('::ffff:')) {
    host = host.substring(7);
  }
  if (host == '::') return '';
  return host;
}
