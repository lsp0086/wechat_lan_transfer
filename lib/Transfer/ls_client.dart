// LocalSend Protocol v2 发送端 HTTP 客户端。
// 对齐官方 packages/core/src/http/client/v2.rs：
// - prepare-upload 挂起直到接收方决策（无短超时，取消 = abort 断开连接）
// - upload 流式发送 + 进度回调 + 422 哈希不匹配自动重试（同 token ≤3 次）
// - HTTPS 自签证书：badCertificateCallback 内比对发现层 fingerprint（TOFU 钉扎）
// - 客户端携带本端证书（mTLS，官方服务端用其做不可伪造身份校验）

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:wechat_lan_transfer/Services/tls_identity_service.dart';
import 'package:wechat_lan_transfer/Transfer/ls_dto.dart';

/// 可取消令牌：cancel() 会 abort 已绑定的 in-flight 请求，
/// 接收方由此感知"发送方已不在等待决策"（连接断开）。
class LsCancelToken {
  bool _cancelled = false;
  final List<HttpClientRequest> _bound = [];
  final _done = Completer<void>();

  bool get isCancelled => _cancelled;

  Future<void> get future => _done.future;

  void bind(HttpClientRequest request) {
    if (_cancelled) {
      request.abort();
      return;
    }
    _bound.add(request);
  }

  void unbind(HttpClientRequest request) => _bound.remove(request);

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final r in List<HttpClientRequest>.of(_bound)) {
      try {
        r.abort();
      } catch (_) {}
    }
    _bound.clear();
    if (!_done.isCompleted) _done.complete();
  }
}

/// v2 客户端。一个进程一个实例即可（内部按需复用 HttpClient）。
class LsClient {
  LsClient._();
  static final LsClient instance = LsClient._();

  HttpClient? _shared;

  /// 构造（或复用）HttpClient：
  /// - 不携带本端证书：dart:io 服务端对 requestClientCertificate=true 会强
  ///   校验客户端证书链，对端自签证书必被拒（握手即断）——对端身份由
  ///   announce/register 自报 fingerprint + 本端 badCertificateCallback 钉扎保证；
  /// - badCertificateCallback 按预期指纹钉扎；预期为空时仅 discovery 用途。
  HttpClient _http(String? expectedFingerprint) {
    final fp = (expectedFingerprint ?? '').trim().toLowerCase();
    HttpClient? client = _shared;
    // 指纹变化时重建（钉扎在握手回调里闭包捕获 fp）
    if (client != null && client._lsFingerprint != fp) {
      try {
        client.close(force: true);
      } catch (_) {}
      client = null;
    }
    if (client == null) {
      // 空上下文（无本端证书、无信任根）：服务端证书一律走钉扎回调判定
      final ctx = SecurityContext();
      client = HttpClient(context: ctx)
        ..connectionTimeout = const Duration(seconds: 10)
        ..badCertificateCallback = (cert, host, port) {
          if (fp.isEmpty) return true; // 仅发现场景；传输必须带预期指纹
          return TlsIdentityService.fingerprintOfCert(cert) == fp;
        };
      client._lsFingerprint = fp;
      _shared = client;
    }
    return client;
  }

  /// POST /api/localsend/v2/prepare-upload
  /// 挂起直到接收方接受（200）/拒绝（403）/要求 PIN（401）/忙（409）。
  /// 成功返回 sessionId + fileId->token map；204（全拒/空）按 rejected 处理。
  Future<LsPrepareUploadResponse> prepareUpload({
    required String ip,
    required int port,
    required LsDeviceDto info,
    required Map<String, LsFileDto> files,
    String? pin,
    required String? expectedFingerprint,
    LsCancelToken? cancel,
  }) async {
    final body = jsonEncode(
      LsPrepareUploadRequest(info: info, files: files).toJson(),
    );
    final uri = Uri.parse(
      'https://${_hostFor(ip)}:$port/api/localsend/v2/prepare-upload'
      '${(pin != null && pin.isNotEmpty) ? '?pin=${Uri.encodeQueryComponent(pin)}' : ''}',
    );

    final req = await _http(expectedFingerprint).postUrl(uri);
    req.headers.contentType = ContentType.json;
    req.write(body);
    cancel?.bind(req);
    try {
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode == 200) {
        try {
          return LsPrepareUploadResponse.fromJson(
            jsonDecode(text) as Map<String, dynamic>,
          );
        } catch (e) {
          // 200 但 body 非法（如对端异常提前关流返回空体）
          throw LsSendError(LsErrorKind.unknown, 0, '响应解析失败: $e');
        }
      }
      throw LsSendError.fromStatus(res.statusCode, text);
    } on LsSendError {
      rethrow;
    } on HandshakeException {
      if (cancel?.isCancelled ?? false) {
        throw const LsSendError(LsErrorKind.rejected, 0, '已取消');
      }
      throw const LsSendError(
        LsErrorKind.unknown,
        0,
        '对端证书指纹不匹配，可能存在中间人攻击',
      );
    } on SocketException catch (e) {
      if (cancel?.isCancelled ?? false) {
        throw const LsSendError(LsErrorKind.rejected, 0, '已取消');
      }
      throw LsSendError(LsErrorKind.unknown, 0, '连接失败: ${e.message}');
    } on HttpException catch (e) {
      // request.abort() 会让挂起的 close() 抛 HttpException
      if (cancel?.isCancelled ?? false) {
        throw const LsSendError(LsErrorKind.rejected, 0, '已取消');
      }
      throw LsSendError(LsErrorKind.unknown, 0, e.message);
    } finally {
      cancel?.unbind(req);
    }
  }

  /// POST /api/localsend/v2/upload?sessionId&fileId&token
  /// 流式发送文件内容；[onProgress] 按已发送字节回调（节流由调用方处理）。
  /// 422（哈希不匹配）自动整文件重试，同 token 最多 3 次尝试（对齐官方）。
  Future<void> uploadFile({
    required String ip,
    required int port,
    required String sessionId,
    required String fileId,
    required String token,
    required String filePath,
    required int fileSize,
    required String? expectedFingerprint,
    void Function(int sent, int total)? onProgress,
    LsCancelToken? cancel,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw const LsSendError(LsErrorKind.unknown, 0, '本地文件不存在');
    }
    final total = fileSize > 0 ? fileSize : await file.length();
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        await _uploadOnce(
          ip: ip,
          port: port,
          sessionId: sessionId,
          fileId: fileId,
          token: token,
          filePath: filePath,
          total: total,
          expectedFingerprint: expectedFingerprint,
          onProgress: onProgress,
          cancel: cancel,
        );
        return;
      } on LsSendError catch (e) {
        // 官方语义：422 后服务端把文件重置回 Pending，可带原 token 重试。
        if (e.kind == LsErrorKind.checksumMismatch && attempt < 3) {
          debugPrint('[LsClient] 哈希不匹配，重试 $attempt/3: ${file.path}');
          continue;
        }
        rethrow;
      }
    }
  }

  Future<void> _uploadOnce({
    required String ip,
    required int port,
    required String sessionId,
    required String fileId,
    required String token,
    required String filePath,
    required int total,
    required String? expectedFingerprint,
    void Function(int sent, int total)? onProgress,
    LsCancelToken? cancel,
  }) async {
    final uri = Uri.parse(
      'https://${_hostFor(ip)}:$port/api/localsend/v2/upload'
      '?sessionId=${Uri.encodeQueryComponent(sessionId)}'
      '&fileId=${Uri.encodeQueryComponent(fileId)}'
      '&token=${Uri.encodeQueryComponent(token)}',
    );

    final req = await _http(expectedFingerprint).postUrl(uri);
    req.headers.contentLength = total;
    var sent = 0;
    final stream = File(filePath).openRead().map((chunk) {
      sent += chunk.length;
      onProgress?.call(sent, total);
      return chunk;
    });
    cancel?.bind(req);
    try {
      await req.addStream(stream);
      final res = await req.close();
      // 消费完响应体以释放连接
      await res.drain<void>();
      if (res.statusCode != 200) {
        throw LsSendError.fromStatus(res.statusCode, '');
      }
    } on LsSendError {
      rethrow;
    } on HandshakeException {
      throw const LsSendError(
        LsErrorKind.unknown,
        0,
        '对端证书指纹不匹配，可能存在中间人攻击',
      );
    } on SocketException catch (e) {
      if (cancel?.isCancelled ?? false) {
        throw const LsSendError(LsErrorKind.rejected, 0, '已取消');
      }
      throw LsSendError(LsErrorKind.unknown, 0, '连接中断: ${e.message}');
    } on HttpException catch (e) {
      // 流中途中止（abort）同样以 HttpException 浮出
      if (cancel?.isCancelled ?? false) {
        throw const LsSendError(LsErrorKind.rejected, 0, '已取消');
      }
      throw LsSendError(LsErrorKind.unknown, 0, e.message);
    } finally {
      cancel?.unbind(req);
    }
  }

  /// POST /api/localsend/v2/cancel?sessionId
  /// 通知对端取消会话：
  /// - 对端正在等我们传（active/pending）→ 释放其会话槽；
  /// - 对端在向我们传（我们自己的发送会话）→ 对端应取消发送。
  /// 尽力而为：取消失败不影响主流程。用独立连接，避免共享 HttpClient
  /// 的连接池被 abort 过的请求污染。
  Future<void> cancelSession({
    required String ip,
    required int port,
    required String sessionId,
    String? expectedFingerprint,
  }) async {
    HttpClient? client;
    try {
      final uri = Uri.parse(
        'https://${_hostFor(ip)}:$port/api/localsend/v2/cancel'
        '?sessionId=${Uri.encodeQueryComponent(sessionId)}',
      );
      final fp = (expectedFingerprint ?? '').trim().toLowerCase();
      client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5)
        ..badCertificateCallback = (cert, host, p) {
          if (fp.isEmpty) return true;
          return TlsIdentityService.fingerprintOfCert(cert) == fp;
        };
      final req = await client.postUrl(uri);
      final res = await req.close();
      await res.drain<void>();
    } catch (e) {
      debugPrint('[LsClient] cancel 失败（忽略）: $e');
    } finally {
      try {
        client?.close(force: true);
      } catch (_) {}
    }
  }

  /// IPv6 裸地址补方括号；IPv4/主机名原样。
  static String _hostFor(String ip) {
    final t = ip.trim();
    if (t.startsWith('[')) return t; // 已是 [::1] 形式
    if (t.contains(':')) return '[$t]';
    return t;
  }
}

extension on HttpClient {
  // 钉扎指纹标记（重建 HttpClient 的依据），存于实例上避免全局可变状态。
  static final _fpExp = Expando<String>();
  String get _lsFingerprint => _fpExp[this] ?? '';
  set _lsFingerprint(String v) => _fpExp[this] = v;
}
