import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'protocol_codec.dart';

/// E3-遗留：消息缓存落盘机密性（对标 SQLCipher 目标，应用层实现——
/// 无需原生编译链，跨 Android/iOS/桌面一致）。
/// payload（jsonEncode 后）落盘前 seal 为 `enc1:` + Base64(iv||cipher||tag)，
/// 读取时 open 解密；无前缀的旧行（历史明文）原样返回，渐进迁移。
/// 密钥 256bit 随机，存 Keychain/Keystore/DPAPI（与私钥/PIN 同一套安全存储），
/// 读写失败自动降级明文（不影响可用性）。

/// secure_storage 键名（E3：缓存加密密钥）。
const String kCacheEncKeyStorage = 'cache_enc_key';

/// 密文前缀（版本 1）。
const String kCacheCipherPrefix = 'enc1:';

/// 懒加载/首次生成缓存加密密钥（32 字节随机 → base64）。
/// 读取失败返回空串，调用方按明文降级处理。
Future<String> loadOrCreateCacheKey({
  FlutterSecureStorage? secure,
  Random? rng,
}) async {
  final store = secure ??
      const FlutterSecureStorage(
        aOptions: AndroidOptions(encryptedSharedPreferences: true),
        iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
      );
  try {
    final existing = await store.read(key: kCacheEncKeyStorage);
    if (existing != null && existing.isNotEmpty) return existing;
    final r = rng ?? Random.secure();
    final key = base64Encode(
      List<int>.generate(32, (_) => r.nextInt(256)),
    );
    await store.write(key: kCacheEncKeyStorage, value: key);
    return key;
  } catch (e) {
    debugPrint('[CacheCrypto] 缓存密钥读取失败，降级明文: $e');
    return '';
  }
}

/// 加密 payload：`enc1:` 前缀 + encryptText b64。key 为空（降级）时原样返回。
String sealPayload(String json, String key) {
  if (key.isEmpty) return json;
  final sealed = ProtocolCodec.encryptText(json, key);
  if (sealed.isEmpty) return json;
  return '$kCacheCipherPrefix$sealed';
}

/// 解密 payload：带前缀则解密（tag 失败/格式错返回 null）；无前缀视为
/// 历史明文行原样返回（渐进迁移）。key 为空时仅放行明文行。
String? openPayload(String stored, String key) {
  if (!stored.startsWith(kCacheCipherPrefix)) return stored;
  if (key.isEmpty) return null;
  return ProtocolCodec.decryptText(
    stored.substring(kCacheCipherPrefix.length),
    key,
  );
}
