// LocalSend v2 server + client 回环集成测试（内存自签证书，真实 HTTPS）。
// 覆盖：接受/拒绝/忙(409)/PIN(401/429)/上传+sha256/发送方取消(pending)。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wechat_lan_transfer/Transfer/file_utils.dart';
import 'package:wechat_lan_transfer/Transfer/ls_client.dart';
import 'package:wechat_lan_transfer/Transfer/ls_dto.dart';
import 'package:wechat_lan_transfer/Transfer/ls_server.dart';

/// 生成内存自签证书 + SecurityContext（同 TlsIdentityService 的生成方式）。
(SecurityContext, String) _makeCert() {
  final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
  final privateKey = pair.privateKey as RSAPrivateKey;
  final publicKey = pair.publicKey as RSAPublicKey;
  final keyPem = CryptoUtils.encodeRSAPrivateKeyToPemPkcs1(privateKey);
  final csrPem = X509Utils.generateRsaCsrPem(
    {'CN': 'ls-test', 'O': 'ls-test'},
    privateKey,
    publicKey,
  );
  final certPem = X509Utils.generateSelfSignedCertificate(
    privateKey,
    csrPem,
    365,
  );
  final ctx = SecurityContext()
    ..useCertificateChainBytes(utf8.encode(certPem))
    ..usePrivateKeyBytes(utf8.encode(keyPem));
  final der = base64.decode(
    certPem
        .replaceAll('-----BEGIN CERTIFICATE-----', '')
        .replaceAll('-----END CERTIFICATE-----', '')
        .replaceAll(RegExp(r'\s'), ''),
  );
  return (ctx, sha256.convert(der).toString());
}

LsDeviceDto _selfInfo(String fp, int port) => LsDeviceDto(
      alias: 'TestReceiver',
      fingerprint: fp,
      port: port,
    );

Map<String, LsFileDto> _oneFile(String path, {String? sha}) {
  final f = File(path);
  final size = f.lengthSync();
  return {
    'f1': LsFileDto(
      id: 'f1',
      fileName: 'hello.txt',
      size: size,
      fileType: 'text/plain',
      sha256: sha,
    ),
  };
}

void main() {
  // 注意：不要调 TestWidgetsFlutterBinding.ensureInitialized()——
  // 它会把所有 HttpClient 请求劫持为 400，真实回环 HTTPS 走不通。
  late Directory tmpDir;
  late SecurityContext ctx;
  late String fingerprint;
  late LsServer server;
  late int port;
  final rnd = DateTime.now().microsecondsSinceEpoch % 10000;

  setUpAll(() async {
    tmpDir = await Directory.systemTemp.createTemp('ls_test_');
    (ctx, fingerprint) = _makeCert();
  });

  setUp(() async {
    server = LsServer();
    port = 53400 + rnd;
    await server.start(
      preferredPort: port,
      tlsContext: ctx,
      saveDir: tmpDir.path,
    );
    port = server.boundPort;
  });

  tearDown(() {
    server.stop();
  });

  tearDownAll(() async {
    await tmpDir.delete(recursive: true);
  });

  LsDeviceDto senderInfo() => LsDeviceDto(
        alias: 'TestSender',
        fingerprint: 'a' * 64,
        port: 1234,
      );

  test('接受 → 上传 → 落盘 + sha256 校验', () async {
    final src = File('${tmpDir.path}/src.txt');
    final content = List.generate(1000, (i) => i % 256).join(',');
    await src.writeAsString(content);
    final sha = await lsSha256OfFile(src.path);

    LsIncomingRequest? seen;
    server.onPrepareUpload = (req) async {
      seen = req;
      return LsAccept(req.files.keys.toSet());
    };

    final res = await LsClient.instance.prepareUpload(
      ip: '127.0.0.1',
      port: port,
      info: senderInfo(),
      files: _oneFile(src.path, sha: sha),
      expectedFingerprint: fingerprint,
    );
    expect(res.sessionId, isNotEmpty);
    expect(res.files['f1'], isNotEmpty);
    expect(seen!.sender.alias, 'TestSender');
    expect(seen!.files['f1']!.fileName, 'hello.txt');

    final done = Completer<LsFileResult>();
    server.onFileResult = done.complete;
    await LsClient.instance.uploadFile(
      ip: '127.0.0.1',
      port: port,
      sessionId: res.sessionId,
      fileId: 'f1',
      token: res.files['f1']!,
      filePath: src.path,
      fileSize: src.lengthSync(),
      expectedFingerprint: fingerprint,
      onProgress: (sent, total) {},
    );
    final result = await done.future.timeout(const Duration(seconds: 10));
    expect(result.success, isTrue);
    expect(result.savedPath, isNotNull);
    expect(File(result.savedPath!).readAsStringSync(), content);
  });

  test('拒绝 → 403 rejected', () async {
    server.onPrepareUpload = (_) async => const LsDecline();
    final src = File('${tmpDir.path}/src2.txt');
    await src.writeAsString('x');
    await expectLater(
      LsClient.instance.prepareUpload(
        ip: '127.0.0.1',
        port: port,
        info: senderInfo(),
        files: _oneFile(src.path),
        expectedFingerprint: fingerprint,
      ),
      throwsA(
        isA<LsSendError>()
            .having((e) => e.kind, 'kind', LsErrorKind.rejected),
      ),
    );
  });

  test('单会话槽：决策挂起时第二个 prepare-upload → 409 busy', () async {
    final gate = Completer<void>();
    server.onPrepareUpload = (_) => gate.future.then(
          (_) => const LsDecline(),
        );
    final src = File('${tmpDir.path}/src3.txt');
    await src.writeAsString('x');

    final first = LsClient.instance.prepareUpload(
      ip: '127.0.0.1',
      port: port,
      info: senderInfo(),
      files: _oneFile(src.path),
      expectedFingerprint: fingerprint,
    );

    // 等第一个请求确实到达（槽位被占）
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await expectLater(
      LsClient.instance.prepareUpload(
        ip: '127.0.0.1',
        port: port,
        info: senderInfo(),
        files: _oneFile(src.path),
        expectedFingerprint: fingerprint,
      ),
      throwsA(isA<LsSendError>().having((e) => e.kind, 'kind',
          LsErrorKind.busy)),
    );

    gate.complete();
    await expectLater(first,
        throwsA(isA<LsSendError>()));
  });

  test('PIN：缺 PIN → 401；错 PIN 多次 → 429；对 PIN → 200', () async {
    server.receivePinProvider = () async => '1234';
    final src = File('${tmpDir.path}/src4.txt');
    await src.writeAsString('x');
    final files = _oneFile(src.path);

    // 缺 PIN
    await expectLater(
      LsClient.instance.prepareUpload(
        ip: '127.0.0.1',
        port: port,
        info: senderInfo(),
        files: files,
        expectedFingerprint: fingerprint,
      ),
      throwsA(isA<LsSendError>()
          .having((e) => e.kind, 'kind', LsErrorKind.pinRequired)),
    );

    // 错 PIN 4 次 → 第 4 次起 429（PinFailLimiter: >maxFails 阻断）
    for (var i = 0; i < 4; i++) {
      await expectLater(
        LsClient.instance.prepareUpload(
          ip: '127.0.0.1',
          port: port,
          info: senderInfo(),
          files: files,
          pin: '0000',
          expectedFingerprint: fingerprint,
        ),
        throwsA(isA<LsSendError>().having(
            (e) => e.kind, 'kind $i',
            i < 2 ? LsErrorKind.pinRequired : LsErrorKind.tooManyRequests)),
      );
    }
  });

  test('发送方 pending 阶段取消（cancel 端点）→ 请求以 403 结束 + 会话 cancelled',
      () async {
    final gate = Completer<void>();
    LsIncomingRequest? seenReq;
    server.onPrepareUpload = (req) {
      seenReq = req;
      return gate.future.then((_) => LsAccept(req.files.keys.toSet()));
    };
    LsSessionEndReason? endReason;
    server.onSessionEnd = (id, reason) => endReason = reason;

    final src = File('${tmpDir.path}/src5.txt');
    await src.writeAsString('x');
    final cancel = LsCancelToken();
    final pending = LsClient.instance.prepareUpload(
      ip: '127.0.0.1',
      port: port,
      info: senderInfo(),
      files: _oneFile(src.path),
      expectedFingerprint: fingerprint,
      cancel: cancel,
    );
    // 提前挂空监听：pending 的错误可能在 expectLater 之前完成（如 /cancel
    // 后服务端立即回 403）——无监听的 Future 错误会成为 unhandled async error
    pending.then<void>((_) {}, onError: (Object _) {});

    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(seenReq, isNotNull);
    // 发送方先走 /cancel（官方行为），再 abort 请求
    await LsClient.instance.cancelSession(
      ip: '127.0.0.1',
      port: port,
      sessionId: seenReq!.sessionId,
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(endReason, anyOf(LsSessionEndReason.cancelled,
        LsSessionEndReason.aborted));

    cancel.cancel();
    await expectLater(pending, throwsA(isA<LsSendError>()));
  });

  test('发送方直接断开（abort）→ pending 清理 aborted', () async {
    final block = Completer<void>();
    server.onPrepareUpload = (req) {
      return block.future.then((_) => LsAccept(req.files.keys.toSet()));
    };
    LsSessionEndReason? endReason;
    server.onSessionEnd = (id, reason) => endReason = reason;

    final src = File('${tmpDir.path}/src6.txt');
    await src.writeAsString('x');
    final cancel = LsCancelToken();
    final pending = LsClient.instance.prepareUpload(
      ip: '127.0.0.1',
      port: port,
      info: senderInfo(),
      files: _oneFile(src.path),
      expectedFingerprint: fingerprint,
      cancel: cancel,
    );
    // 提前挂空监听：pending 的错误可能在 expectLater 之前完成（如 /cancel
    // 后服务端立即回 403）——无监听的 Future 错误会成为 unhandled async error
    pending.then<void>((_) {}, onError: (Object _) {});

    await Future<void>.delayed(const Duration(milliseconds: 300));
    cancel.cancel(); // 直接 abort，不发 /cancel
    await expectLater(pending, throwsA(isA<LsSendError>()));
    // 给服务端一点时间感知断开
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(endReason, LsSessionEndReason.aborted);
    block.complete();
  });

  test('info 端点返回本端设备信息', () async {
    server.selfInfo = () => _selfInfo(fingerprint, port);
    final client = HttpClient()
      ..badCertificateCallback = (cert, host, port) => true;
    final req = await client
        .getUrl(Uri.parse('https://127.0.0.1:$port/api/localsend/v2/info'));
    final res = await req.close();
    final body =
        jsonDecode(await res.transform(utf8.decoder).join())
            as Map<String, dynamic>;
    expect(body['alias'], 'TestReceiver');
    expect(body['fingerprint'], fingerprint);
    client.close(force: true);
  });
}
