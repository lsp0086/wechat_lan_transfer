import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// P0-1：本端 TLS 身份（RSA-2048 自签证书）管理服务。
///
/// 首次运行生成自签证书并持久化到 应用文档目录/identity/{cert.pem,key.pem}，
/// 之后启动直接加载。证书指纹（SHA-256(DER) hex 小写）随 UDP 握手消息
/// （file_notify / file_accept）透传，对方在 TLS 握手后校验证书指纹，
/// 防止中间人攻击（TOFU 之外不做 CA 信任链校验）。
class TlsIdentityService {
  TlsIdentityService._();
  static final TlsIdentityService instance = TlsIdentityService._();

  // 幂等 init 的防重入锁：并发调用共享同一个 Future
  Completer<void>? _initCompleter;
  SecurityContext? _serverContext;
  String _fingerprint = '';

  // S4：安卓/iOS/macOS/Windows 私钥迁入系统安全存储（Keychain/Keystore/DPAPI 加密存储），
  // 仅证书仍可落盘；迁移后删除旧 key.pem。
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );
  static const _keyCertPem = 'identity_cert_pem';
  static const _keyKeyPem = 'identity_key_pem';

  /// 本端证书指纹（DER 的 SHA-256，hex 小写）。未 init 成功时为空串。
  String get fingerprint => _fingerprint;

  /// P0-7：本端持久 deviceId —— 直接复用 TLS 证书指纹（重启/换 IP 均不变），
  /// 替代"IP 即身份"。未 init 成功时为空串，此时协议层不加 deviceId 字段。
  String get deviceId => fingerprint;

  /// 接收服务端 TLS 用的 SecurityContext（已加载本端证书链与私钥）。
  SecurityContext? get serverContext => _serverContext;

  bool get isReady => _serverContext != null && _fingerprint.isNotEmpty;

  /// 计算 peer 证书的指纹（DER 的 SHA-256，hex 小写），用于指纹钉扎校验。
  static String fingerprintOfCert(X509Certificate cert) {
    return sha256.convert(cert.der).toString().toLowerCase();
  }

  /// 初始化（幂等，并发安全）：首次生成自签证书，之后直接加载。
  Future<void> init() {
    final existing = _initCompleter;
    if (existing != null) return existing.future;
    final completer = Completer<void>();
    _initCompleter = completer;
    _initInternal().then((_) {
      completer.complete();
    }).catchError((Object e) {
      // 失败后允许重试
      _initCompleter = null;
      completer.completeError(e);
      debugPrint('[TlsIdentity] 初始化失败: $e');
    });
    return completer.future;
  }

  Future<void> _initInternal() async {
    final docDir = await getApplicationDocumentsDirectory();
    final idDir = Directory('${docDir.path}/identity');
    if (!await idDir.exists()) {
      await idDir.create(recursive: true);
    }
    await _tightenDirPermission(idDir);
    final certFile = File('${idDir.path}/cert.pem');
    final legacyKeyFile = File('${idDir.path}/key.pem');

    String certPem;
    String keyPem;
    final storedCert = await _secureStorage.read(key: _keyCertPem);
    final storedKey = await _secureStorage.read(key: _keyKeyPem);
    if (storedCert != null &&
        storedCert.isNotEmpty &&
        storedKey != null &&
        storedKey.isNotEmpty) {
      certPem = storedCert;
      keyPem = storedKey;
      debugPrint('[TlsIdentity] 已从安全存储加载证书');
      if (!await certFile.exists()) {
        await certFile.writeAsString(certPem);
        await _tightenFilePermission(certFile, ownerOnly: false);
      }
      if (await legacyKeyFile.exists()) {
        try {
          await legacyKeyFile.delete();
        } catch (_) {}
      }
      await _tightenDirPermission(idDir);
    } else if (await certFile.exists() && await legacyKeyFile.exists()) {
      certPem = await certFile.readAsString();
      keyPem = await legacyKeyFile.readAsString();
      debugPrint('[TlsIdentity] 已加载历史落盘证书，正在迁移到安全存储');
      try {
        await _secureStorage.write(key: _keyCertPem, value: certPem);
        await _secureStorage.write(key: _keyKeyPem, value: keyPem);
        try {
          await legacyKeyFile.delete();
        } catch (_) {}
      } catch (e) {
        debugPrint('[TlsIdentity] 安全存储迁移失败，保留旧文件: $e');
      }
      await _tightenDirPermission(idDir);
    } else {
      debugPrint('[TlsIdentity] 首次运行，生成 RSA-2048 自签证书...');
      final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
      final privateKey = pair.privateKey as RSAPrivateKey;
      final publicKey = pair.publicKey as RSAPublicKey;
      keyPem = CryptoUtils.encodeRSAPrivateKeyToPemPkcs1(privateKey);
      // basic_utils 5.8+：先 CSR 再自签（直接传 subject 会在运行时抛
      // PEM 解析错 → 证书生成失败 → 静默降级明文 → tlsOnly 下所有入站被拒）。
      final csrPem = X509Utils.generateRsaCsrPem(
        {'CN': 'WeChatLANTransfer', 'O': 'WeChatLANTransfer'},
        privateKey,
        publicKey,
      );
      certPem = X509Utils.generateSelfSignedCertificate(
        privateKey,
        csrPem,
        365 * 20, // 证书有效期 20 年（局域网内部自签）
      );
      try {
        await _secureStorage.write(key: _keyCertPem, value: certPem);
        await _secureStorage.write(key: _keyKeyPem, value: keyPem);
      } catch (e) {
        debugPrint('[TlsIdentity] 安全存储写入失败，降级落盘备份: $e');
        await legacyKeyFile.writeAsString(keyPem);
        await _tightenFilePermission(legacyKeyFile, ownerOnly: true);
      }
      await certFile.writeAsString(certPem);
      await _tightenFilePermission(certFile, ownerOnly: false);
      await _tightenDirPermission(idDir);
      debugPrint('[TlsIdentity] 证书已生成: ${certFile.path}');
    }

    final der = base64.decode(
      certPem
          .replaceAll('-----BEGIN CERTIFICATE-----', '')
          .replaceAll('-----END CERTIFICATE-----', '')
          .replaceAll(RegExp(r'\s'), ''),
    );
    _fingerprint = sha256.convert(der).toString().toLowerCase();
    _serverContext = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(certPem))
      ..usePrivateKeyBytes(utf8.encode(keyPem));
    debugPrint('[TlsIdentity] 本端证书指纹: $_fingerprint');
  }

  /// P0-S6：重置本机身份（换证）：删除持久化的 cert.pem/key.pem，
  /// 清空内存状态后重新 init() 生成新证书。调用方需提示对端重新配对
  /// （指纹已变更，旧 TOFU 信任失效）。S4：同步清理安全存储备份。
  Future<void> resetIdentity() async {
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final idDir = Directory('${docDir.path}/identity');
      final certFile = File('${idDir.path}/cert.pem');
      final keyFile = File('${idDir.path}/key.pem');
      try {
        if (await certFile.exists()) await certFile.delete();
      } catch (e) {
        debugPrint('[TlsIdentity] 删除 cert.pem 失败: $e');
      }
      try {
        if (await keyFile.exists()) await keyFile.delete();
      } catch (e) {
        debugPrint('[TlsIdentity] 删除 key.pem 失败: $e');
      }
      try {
        await _secureStorage.delete(key: _keyCertPem);
        await _secureStorage.delete(key: _keyKeyPem);
      } catch (e) {
        debugPrint('[TlsIdentity] 清理安全存储失败: $e');
      }
    } catch (e) {
      debugPrint('[TlsIdentity] 重置身份时定位 identity 目录失败: $e');
    }
    _fingerprint = '';
    _serverContext = null;
    _initCompleter = null;
    await init();
  }

  /// P0-S5：收紧 cert.pem/key.pem 文件权限。
  /// Linux/macOS：chmod 600；Windows：icacls 移除继承、仅保留当前用户；
  /// 失败只打日志不抛错。
  /// 注：长期方案应将私钥存入 Android Keystore / iOS Keychain，
  /// 避免以明文 PEM 落盘，当前为文件权限收紧的过渡方案。
  /// S4：私钥已迁移到系统安全存储，cert.pem 仅作展示备份；key.pem 不再写入。
  Future<void> _tightenDirPermission(Directory dir) async {
    try {
      if (Platform.isLinux || Platform.isMacOS) {
        await Process.run('chmod', ['700', dir.path]);
      } else if (Platform.isWindows) {
        await _tightenWindowsAcl(dir.path, isDir: true);
      }
      // Android/iOS：应用沙盒私有目录，依赖系统沙盒隔离，无需额外 chmod。
    } catch (e) {
      debugPrint('[TlsIdentity] 收紧 identity 目录权限失败: $e');
    }
  }

  Future<void> _tightenFilePermission(File file, {bool ownerOnly = true}) async {
    try {
      if (Platform.isLinux || Platform.isMacOS) {
        await Process.run('chmod', ['600', file.path]);
      } else if (Platform.isWindows) {
        await _tightenWindowsAcl(file.path, isDir: false);
      }
    } catch (e) {
      debugPrint('[TlsIdentity] 收紧文件权限失败 ${file.path}: $e');
    }
  }

  /// Windows：移除继承并仅保留当前用户读写。失败只打日志不抛错。
  Future<void> _tightenWindowsAcl(String path, {bool isDir = false}) async {
    try {
      final username = Platform.environment['USERNAME'] ??
          Platform.environment['USER'] ??
          '';
      if (username.isEmpty) {
        debugPrint('[TlsIdentity] Windows 未取到当前用户名，跳过 icacls: $path');
        return;
      }
      // /inheritance:r 移除继承；/grant:r 覆盖授权，仅保留当前用户。
      // 目录需加 (OI)(CI) 使子项继承，文件只需 (R,W)。
      final perm =
          isDir ? '$username:(OI)(CI)(R,W)' : '$username:(R,W)';
      final result = await Process.run(
        'icacls',
        [path, '/inheritance:r', '/grant:r', perm],
      );
      if (result.exitCode != 0) {
        debugPrint('[TlsIdentity] icacls 失败($path): ${result.stderr}');
      }
    } catch (e) {
      debugPrint('[TlsIdentity] icacls 异常($path): $e');
    }
  }
}
