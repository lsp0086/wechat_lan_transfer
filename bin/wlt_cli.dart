// U2：极简 CLI（纯 Dart，无 Flutter 依赖，复用 protocol_codec 协议字段）。
// 对标 LocalSend CLI / `--text` 的快传能力。
//
// 用法：
//   dart run bin/wlt_cli.dart --ip 192.168.1.10 [--port 8888] --text "你好"
//   dart run bin/wlt_cli.dart --ip 192.168.1.10 [--port 8888] --stdin
//   dart run bin/wlt_cli.dart --ip 192.168.1.10 [--tcp 8899] --file ./report.pdf
//
// 行为：
//   文字：发送 text_msg（含 v/ts/nonce）→ 等待 msg_ack（默认 2s）→ 报告退出。
//   文件：生成临时自签证书（basic_utils 纯 Dart）→ file_notify（带 tlsFp/hmac，
//   对端 tlsOnly 默认开，无指纹入站直接拒绝）→ 等待 file_accept（token+offset，
//   默认 30s，期间对端弹确认框/自动接收）→ TLS 连接+对端指纹钉扎 →
//   1024B header（token/offset/sha256）→ 流式发送（断点续传 offset 起步）。
// 退出码：0=成功 / 1=传输失败 / 2=参数错误。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:wechat_lan_transfer/Services/protocol_codec.dart';

Future<void> main(List<String> args) async {
  String? ip;
  var udpPort = 8888;
  var tcpPort = 8899;
  String? text;
  String? filePath;
  var useStdin = false;
  var waitPassed = false;
  var waitMs = 2000;
  var name = 'wlt-cli';
  var pin = '';

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--ip':
        ip = args[++i];
      case '--port' || '-p':
        udpPort = int.tryParse(args[++i]) ?? udpPort;
      case '--tcp':
        tcpPort = int.tryParse(args[++i]) ?? tcpPort;
      case '--text' || '-m':
        text = args[++i];
      case '--file' || '-f':
        filePath = args[++i];
      case '--stdin':
        useStdin = true;
      case '--name':
        name = args[++i];
      case '--pin':
        pin = args[++i];
      case '--wait':
        waitMs = int.tryParse(args[++i]) ?? waitMs;
        waitPassed = true;
      case '--help' || '-h':
        _usage();
        return;
      default:
        stderr.writeln('未知参数: ${args[i]}');
        _usage();
        exit(2);
    }
  }

  if (ip == null || ip.isEmpty) {
    stderr.writeln('缺少 --ip');
    _usage();
    exit(2);
  }
  // 文件模式默认给足人工确认时间（对端非自动接收时需在 App 内点"接收"）
  if (filePath != null && !waitPassed) waitMs = 30000;
  if (!useStdin && text == null && filePath == null) {
    stderr.writeln('缺少 --text / --stdin / --file 至少一项');
    exit(2);
  }

  RawDatagramSocket socket;
  try {
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  } catch (e) {
    stderr.writeln('绑定 UDP socket 失败: $e');
    exit(1);
  }

  if (filePath != null) {
    await _sendFile(socket, ip, udpPort, tcpPort, name, filePath, pin, waitMs);
  }

  final messages = <String>[?text];
  if (useStdin) {
    final lines = stdin.readLineSync(encoding: utf8);
    if (lines != null && lines.isNotEmpty) messages.addAll(lines.split('\n'));
  }

  var confirmed = 0;
  for (final msg in messages) {
    if (msg.isEmpty) continue;
    final ok = await _sendText(socket, ip, udpPort, name, msg, waitMs);
    if (ok) {
      confirmed++;
      stdout.writeln('已确认: $msg');
    } else {
      stdout.writeln('超时未确认: $msg（对端可能未运行或不在线）');
    }
  }
  socket.close();
  // 文件失败已在 _sendFile 内 exit(1)，到达此处即文件成功（若有）
  exit(confirmed == messages.length ? 0 : 1);
}

/// 发送一条 text_msg 并等待 msg_ack（对端回 ACK 到本 socket 的来源端口）。
Future<bool> _sendText(
  RawDatagramSocket socket,
  String ip,
  int port,
  String name,
  String content,
  int waitMs,
) async {
  final msgId = '${DateTime.now().millisecondsSinceEpoch}_cli';
  final payload = {
    'cmd': 'text_msg',
    'content': content,
    'senderName': name,
    'msgId': msgId,
    ...ProtocolCodec.newAuthFields(),
    'timestamp': DateTime.now().toIso8601String(),
  };
  socket.send(utf8.encode(jsonEncode(payload)), InternetAddress(ip), port);

  final completer = Completer<bool>();
  final sub = socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    final dg = socket.receive();
    if (dg == null) return;
    if (dg.address.address != ip) return;
    try {
      final decoded = jsonDecode(utf8.decode(dg.data));
      if (decoded is Map &&
          decoded['cmd'] == 'msg_ack' &&
          decoded['msgId'] == msgId) {
        if (!completer.isCompleted) completer.complete(true);
      }
    } catch (_) {}
  });
  try {
    return await completer.future.timeout(
      Duration(milliseconds: waitMs),
      onTimeout: () => false,
    );
  } finally {
    unawaited(sub.cancel());
  }
}

/// U2：发送文件。完整握手复用 App 内发送链路（同信任模型：TLS 指纹钉扎）。
Future<void> _sendFile(
  RawDatagramSocket socket,
  String ip,
  int udpPort,
  int tcpPort,
  String name,
  String filePath,
  String pin,
  int acceptWaitMs,
) async {
  final file = File(filePath);
  if (!await file.exists()) {
    stderr.writeln('文件不存在: $filePath');
    exit(1);
  }
  final fileSize = await file.length();
  final fileName = filePath.split(Platform.pathSeparator).last;

  // 1. 临时 TLS 身份（对端 tlsOnly 默认开，无指纹入站直接拒绝）
  stdout.writeln('生成临时 TLS 身份（RSA-2048）...');
  final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
  final privateKey = pair.privateKey as RSAPrivateKey;
  final publicKey = pair.publicKey as RSAPublicKey;
  final keyPem = CryptoUtils.encodeRSAPrivateKeyToPemPkcs1(privateKey);
  // basic_utils 5.8+：先 CSR 再自签（直接传 subject 会运行时抛 PEM 解析错）
  final csrPem = X509Utils.generateRsaCsrPem(
    {'CN': 'wlt-cli'},
    privateKey,
    publicKey,
  );
  final certPem = X509Utils.generateSelfSignedCertificate(
    privateKey,
    csrPem,
    365,
  );
  final der = base64.decode(
    certPem
        .replaceAll('-----BEGIN CERTIFICATE-----', '')
        .replaceAll('-----END CERTIFICATE-----', '')
        .replaceAll(RegExp(r'\s'), ''),
  );
  final fp = sha256.convert(der).toString().toLowerCase();

  // 2. SHA-256 提前计算（file_notify 携带，接收端落盘后校验）
  stdout.writeln('计算 SHA-256...');
  final sha = (await sha256.bind(file.openRead()).first).toString();

  // 3. file_notify（带 tlsFp + hmac）
  final transferId = 'cli_${DateTime.now().millisecondsSinceEpoch}';
  final notify = {
    'cmd': 'file_notify',
    'fileName': fileName,
    'fileSize': fileSize,
    'senderName': name,
    'isFolder': false,
    'isVoice': false,
    'transferId': transferId,
    'sha256': sha,
    'tlsFp': fp,
    if (pin.isNotEmpty) 'pin': pin,
    ...ProtocolCodec.newAuthFields(deviceId: fp),
    'timestamp': DateTime.now().toIso8601String(),
  };
  notify['hmac'] = ProtocolCodec.hmacFor(notify, fp);
  socket.send(utf8.encode(jsonEncode(notify)), InternetAddress(ip), udpPort);
  stdout.writeln(
    'file_notify 已发送 -> $ip:$udpPort（等待对方确认，最长 ${acceptWaitMs / 1000}s）',
  );

  // 4. 等待 file_accept（token + offset + 对端指纹）
  final accept = await _waitFileAccept(socket, ip, transferId, acceptWaitMs);
  if (accept == null) {
    stderr.writeln('未收到 file_accept（对方未确认/未运行/已拒绝）');
    exit(1);
  }
  final (token, offset, peerFp) = accept;
  stdout.writeln('对方已同意（续传起点 offset=$offset），建立 TLS 连接...');

  // 5. TLS 连接 + 对端指纹钉扎（对端指纹来自 file_accept 的 tlsFp）
  final ctx = SecurityContext()
    ..useCertificateChainBytes(utf8.encode(certPem))
    ..usePrivateKeyBytes(utf8.encode(keyPem));
  final SecureSocket sock;
  try {
    sock = await SecureSocket.connect(
      ip,
      tcpPort,
      context: ctx,
      // 自签放行，身份靠下方指纹校验（与 App 内发送同模式）
      onBadCertificate: (_) => true,
      timeout: const Duration(seconds: 10),
    );
  } catch (e) {
    stderr.writeln('TLS 连接失败: $e');
    exit(1);
  }
  final peer = sock.peerCertificate;
  if (peer == null || peerFp.isEmpty) {
    stderr.writeln('无法获取对端证书（或对端未声明指纹），中断');
    sock.destroy();
    exit(1);
  }
  final actualFp = sha256.convert(peer.der).toString().toLowerCase();
  if (actualFp != peerFp.toLowerCase()) {
    stderr.writeln('对端证书指纹不匹配（疑似中间人），中断');
    sock.destroy();
    exit(1);
  }

  // 6. 1024B header（token/offset/sha256 透传，接收端一次即焚校验）
  final header = {
    'v': 1,
    'fileName': fileName,
    'fileSize': fileSize,
    'taskId': 'cli_send_$transferId',
    'isFolder': false,
    'offset': offset,
    'transferId': transferId,
    if (token.isNotEmpty) 'authToken': token,
    'sha256': sha,
  };
  final (padded, lenBytes) = ProtocolCodec.encodeFileHeader(header);
  sock.add(padded);
  sock.add(lenBytes);

  // 7. 流式发送（续传从 offset 起，每秒打印进度）
  var sent = offset;
  var lastPrint = DateTime.now();
  try {
    await for (final chunk in file.openRead(offset)) {
      sock.add(chunk);
      sent += chunk.length;
      final now = DateTime.now();
      if (now.difference(lastPrint).inMilliseconds >= 1000) {
        final pct = fileSize > 0
            ? (sent * 100 / fileSize).toStringAsFixed(1)
            : '100.0';
        stdout.write('\r进度: $pct%');
        lastPrint = now;
      }
    }
    await sock.flush();
    await sock.close();
  } catch (e) {
    stderr.writeln('\n发送失败: $e');
    sock.destroy();
    exit(1);
  }
  stdout.writeln('\n发送完成: $fileName ($sent/$fileSize)');
}

/// 等待 file_accept（对端回包到本 socket 来源端口）。
Future<(String, int, String)?> _waitFileAccept(
  RawDatagramSocket socket,
  String ip,
  String transferId,
  int waitMs,
) async {
  final completer = Completer<(String, int, String)?>();
  final sub = socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    final dg = socket.receive();
    if (dg == null) return;
    if (dg.address.address != ip) return;
    try {
      final decoded = jsonDecode(utf8.decode(dg.data));
      if (decoded is Map &&
          decoded['cmd'] == 'file_accept' &&
          decoded['transferId'] == transferId) {
        if (!completer.isCompleted) {
          completer.complete((
            (decoded['authToken'] as String?) ?? '',
            (decoded['acceptedOffset'] as num?)?.toInt() ?? 0,
            (decoded['tlsFp'] as String?) ?? '',
          ));
        }
      }
    } catch (_) {}
  });
  try {
    return await completer.future.timeout(
      Duration(milliseconds: waitMs),
      onTimeout: () => null,
    );
  } finally {
    unawaited(sub.cancel());
  }
}

void _usage() {
  stdout.writeln('''
局域网快传 CLI（U2）
用法:
  dart run bin/wlt_cli.dart --ip <IP> [--port 8888] --text "<文字>"
  dart run bin/wlt_cli.dart --ip <IP> [--port 8888] --stdin
  dart run bin/wlt_cli.dart --ip <IP> [--tcp 8899] --file <路径>
参数:
  --ip <IP>       对端 IPv4/IPv6 地址（必填）
  --port <端口>   对端 UDP 发现端口，默认 8888
  --tcp <端口>    对端 TCP 文件端口（--file 用），默认 8899
  --text <文字>   要发送的文字（可与 --file 共用）
  --file <路径>   要发送的文件（完整 TLS 握手，对端确认后传输）
  --stdin         从标准输入逐行读取发送
  --pin <数字>    对端启用接收 PIN 时携带
  --name <名字>   本机显示名，默认 wlt-cli
  --wait <毫秒>   等待时长，文字 ACK 默认 2000，文件确认默认 30000
  --help          显示帮助''');
}
