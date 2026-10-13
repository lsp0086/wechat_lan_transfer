import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'transfer_limits.dart';

/// P2-2：可单测的纯协议逻辑（header 编解码 / 握手键 / 退避），不依赖 dart:io。

class ProtocolCodec {
  ProtocolCodec._();

  /// P0-S1：UDP 控制通道协议版本。未知版本拒绝并提示升级。
  static const int protocolVersion = 1;

  /// P0-S1/P1-T8：UDP 单包上限（字节），超限直接丢弃不做 jsonDecode。
  static const int maxUdpPacketBytes = 60000;

  /// P0-S1：重放时间窗（秒），超出窗口的包直接丢弃。
  static const int replayWindowSeconds = 120;

  static final Random _rand = Random.secure();

  /// P0-S1：生成本次发送的 ts（毫秒）/nonce/v 鉴别字段。
  static Map<String, dynamic> newAuthFields({String deviceId = ''}) {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final nonce =
        '${ts.toRadixString(16)}${_rand.nextInt(1 << 32).toRadixString(16)}${_rand.nextInt(1 << 32).toRadixString(16)}';
    final m = <String, dynamic>{
      'v': protocolVersion,
      'ts': ts,
      'nonce': nonce,
    };
    if (deviceId.isNotEmpty) m['deviceId'] = deviceId;
    return m;
  }

  /// P0-S1：时间窗校验。兼容旧端 ISO8601 `timestamp` 字符串与新 `ts` 毫秒时间戳。
  static bool isTimestampFresh(
    dynamic ts, {
    int? nowMs,
    int windowSeconds = replayWindowSeconds,
  }) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    int? tsMs;
    if (ts is int) {
      tsMs = ts;
    } else if (ts is num) {
      tsMs = ts.toInt();
    } else if (ts is String) {
      final asInt = int.tryParse(ts);
      if (asInt != null) {
        tsMs = asInt;
      } else {
        try {
          tsMs = DateTime.parse(ts).millisecondsSinceEpoch;
        } catch (_) {
          return false;
        }
      }
    } else {
      return false;
    }
    final diff = (now - tsMs).abs();
    return diff <= windowSeconds * 1000;
  }

  /// P0-S1：HMAC-SHA256 鉴别。key 为发送方 fingerprint。
  /// 注意：调用方计算前须先移除 `hmac` 字段本身。
  /// 安全注记：fingerprint 随广播明文可被嗅探，此 HMAC 仅防随机损坏/误发，
  /// 不防主动伪造；真正鉴别靠 TLS 指纹钉扎 + 可选 PIN（见 S2）。
  static String hmacFor(Map payload, String key) {
    final sortedKeys = payload.keys.map((e) => e.toString()).toList()..sort();
    final canonical = StringBuffer();
    for (final k in sortedKeys) {
      if (k == 'hmac') continue;
      canonical.write(k);
      canonical.write('=');
      canonical.write(jsonEncode(payload[k]));
      canonical.write(';');
    }
    final hmac = Hmac(sha256, utf8.encode(key));
    return hmac.convert(utf8.encode(canonical.toString())).toString();
  }

  /// S1：校验 HMAC。无 hmac 字段返回 false；key 为空返回 false。
  /// 常数时间比较防时序侧信道（短串场景够用）。
  static bool verifyHmac(Map payload, String key) {
    if (key.isEmpty) return false;
    final got = payload['hmac'];
    if (got is! String || got.isEmpty) return false;
    final expect = hmacFor(payload, key);
    if (got.length != expect.length) return false;
    var diff = 0;
    for (var i = 0; i < got.length; i++) {
      diff |= got.codeUnitAt(i) ^ expect.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// S6：旧格式宽限截止（UTC）。之后缺 ts/nonce 直接丢弃，不再兼容放行。
  static final DateTime legacyGraceUntil = DateTime.utc(2026, 12, 31);

  /// P0-S1：生成随机 nonce（16 进制）。
  static String newNonce() {
    return '${_rand.nextInt(1 << 32).toRadixString(16).padLeft(8, '0')}'
        '${_rand.nextInt(1 << 32).toRadixString(16).padLeft(8, '0')}'
        '${_rand.nextInt(1 << 32).toRadixString(16).padLeft(8, '0')}'
        '${_rand.nextInt(1 << 32).toRadixString(16).padLeft(8, '0')}';
  }

  /// S7：一次性握手 token（hex 32 字符）。接收端注册后 TCP header 必须
  /// 原样回带并一次即焚，防 UDP 伪造 transferId 抢占连接。
  static String newAuthToken() => newNonce();

  // ========== S5：文字通道加密（双方指纹派生共享密钥 + 流密码 + HMAC 完整性） ==========

  /// S5：从双方 TLS 指纹派生文字通道共享密钥（与顺序无关）。
  /// 注意：指纹在局域网广播中明文可见，此加密仅提供基础机密性，非密钥协商；
  /// 强鉴别仍依赖 TLS 指纹钉扎 + 配对 + PIN。
  static String deriveTextSharedKey(String fpA, String fpB) {
    if (fpA.isEmpty || fpB.isEmpty) return '';
    final lo = fpA.compareTo(fpB) <= 0 ? fpA : fpB;
    final hi = fpA.compareTo(fpB) <= 0 ? fpB : fpA;
    return hmacFor({'lo': lo, 'hi': hi, 'purpose': 'wlt-text-v1'}, lo);
  }

  /// S5：加密文字。返回 Base64( iv(12B) || ciphertext || tag(16B) )，失败返回空串。
  static String encryptText(String plain, String sharedKey) {
    if (sharedKey.isEmpty) return '';
    final keyBytes = utf8.encode(sharedKey);
    final iv = List<int>.generate(12, (_) => _rand.nextInt(256));
    final data = utf8.encode(plain);
    final cipher = _xorStream(data, keyBytes, iv);
    final tag = Hmac(sha256, keyBytes)
        .convert(Uint8List.fromList([...iv, ...cipher]))
        .bytes
        .sublist(0, 16);
    return base64Encode(Uint8List.fromList([...iv, ...cipher, ...tag]));
  }

  /// S5：解密文字。tag 不匹配或格式错返回 null（调用方按解密失败处理）。
  static String? decryptText(String b64, String sharedKey) {
    if (sharedKey.isEmpty || b64.isEmpty) return null;
    try {
      final raw = base64Decode(b64);
      if (raw.length < 12 + 16) return null;
      final iv = raw.sublist(0, 12);
      final tag = raw.sublist(raw.length - 16);
      final cipher = raw.sublist(12, raw.length - 16);
      final keyBytes = utf8.encode(sharedKey);
      final expect = Hmac(sha256, keyBytes)
          .convert(Uint8List.fromList([...iv, ...cipher]))
          .bytes
          .sublist(0, 16);
      var diff = 0;
      for (var i = 0; i < 16; i++) {
        diff |= tag[i] ^ expect[i];
      }
      if (diff != 0) return null;
      return utf8.decode(_xorStream(cipher, keyBytes, iv));
    } catch (_) {
      return null;
    }
  }

  /// S5：HMAC 分组扩展生成的 XOR 流密钥（每分组 HMAC(key, iv||counter)）。
  static List<int> _xorStream(List<int> data, List<int> key, List<int> iv) {
    final out = List<int>.filled(data.length, 0);
    var counter = 0;
    var offset = 0;
    while (offset < data.length) {
      final blockInput = <int>[
        ...iv,
        ...utf8.encode(counter.toRadixString(16).padLeft(8, '0')),
      ];
      final block = Hmac(sha256, key).convert(blockInput).bytes;
      final n = (data.length - offset).clamp(0, block.length);
      for (var i = 0; i < n; i++) {
        out[offset + i] = data[offset + i] ^ block[i];
      }
      offset += n;
      counter++;
    }
    return out;
  }

  /// P0-S1：ISO8601 `timestamp` 新鲜度校验（兼容毫秒 int 字符串）。
  static bool isFreshTimestamp(String? iso, {int maxSkewSec = 120}) {
    if (iso == null || iso.isEmpty) return false;
    int? tsMs = int.tryParse(iso);
    if (tsMs == null) {
      try {
        tsMs = DateTime.parse(iso).millisecondsSinceEpoch;
      } catch (_) {
        return false;
      }
    }
    final diff =
        (DateTime.now().millisecondsSinceEpoch - tsMs).abs();
    return diff <= maxSkewSec * 1000;
  }

  /// P0-S1：设备绑定校验。若同时含 deviceId 与 tlsFp 则要求相等，
  /// 否则（缺任一）返回 false（调用方对旧端缺字段做兼容放行）。
  static bool checkDeviceBinding(Map payload) {
    final d = payload['deviceId'];
    final f = payload['tlsFp'];
    final hasD = d is String && d.isNotEmpty;
    final hasF = f is String && f.isNotEmpty;
    if (hasD && hasF) return d == f;
    return false;
  }

  /// TCP 文件传输头部：固定 1024B 填充 JSON + 4B 大端头长。
  /// 返回 (paddedHeader, lenBytes)，抛错表示超长。
  /// P1-T1：offset/sessionId 透传（缺省 offset=0），P1-T5：缺省 v=1，兼容旧端。
  static (Uint8List, Uint8List) encodeFileHeader(
    Map<String, dynamic> header, {
    int headerSize = 1024,
  }) {
    final normalized = Map<String, dynamic>.from(header);
    normalized.putIfAbsent('v', () => protocolVersion);
    normalized.putIfAbsent('offset', () => 0);
    final headerBytes = utf8.encode(jsonEncode(normalized));
    if (headerBytes.length > headerSize) {
      throw ArgumentError('文件名过长，超出头部限制');
    }
    final paddedHeader = Uint8List(headerSize);
    paddedHeader.setRange(0, headerBytes.length, headerBytes);
    final headerLenBytes = ByteData(4)
      ..setInt32(0, headerBytes.length, Endian.big);
    return (paddedHeader, headerLenBytes.buffer.asUint8List());
  }

  /// 解析收到的头部字节流，返回 header map。非法长度抛错。
  /// P1-T5：v 缺省视为 1 兼容旧端；v>protocolVersion 抛错提示升级。
  static Map<String, dynamic> decodeFileHeader(
    List<int> received, {
    int headerSize = 1024,
  }) {
    if (received.length < headerSize + 4) {
      throw ArgumentError('头部数据不足');
    }
    final headerBytes = Uint8List.fromList(received);
    final headerLen = ByteData.sublistView(
      headerBytes,
      headerSize,
      headerSize + 4,
    ).getInt32(0, Endian.big);
    if (headerLen <= 0 || headerLen > headerSize) {
      throw ArgumentError('非法头部长度 $headerLen');
    }
    final map =
        jsonDecode(utf8.decode(headerBytes.sublist(0, headerLen)))
            as Map<String, dynamic>;
    // P1-T5：协议版本协商；旧端无 v 视为 1；新版本提示升级，不破坏现有流程。
    final v = (map['v'] as num?)?.toInt() ?? 1;
    if (v > protocolVersion) {
      throw ArgumentError('协议版本过新 v=$v，请升级应用后重试');
    }
    return map;
  }

  /// P0-4：握手键——优先 transferId，旧端回退 ip_filename。
  static String handshakeKey({String? transferId, required String ip, required String fileName}) {
    if (transferId != null && transferId.isNotEmpty) return transferId;
    return '${ip}_$fileName';
  }

  /// P1-3：ACK 指数退避（毫秒）——0.8s / 1.6s / 3.2s / 6.4s。
  /// E1：抽至 transfer_limits.kAckBaseTimeoutMs/kWaveformBars。
  static int ackBackoffMs(int retry, {int baseMs = kAckBaseTimeoutMs}) =>
      baseMs * (1 << retry);

  /// P1-7：振幅降采样为固定柱数，返回 0.08~1.0 区间。
  static List<double> downsampleWaveform(
    List<double> amps, {
    int bars = kWaveformBars,
  }) {
    if (amps.isEmpty) return List<double>.filled(bars, 0.15);
    final result = <double>[];
    for (int i = 0; i < bars; i++) {
      final start = (i * amps.length / bars).floor().clamp(0, amps.length - 1);
      final rawEnd = ((i + 1) * amps.length / bars).ceil();
      final end = rawEnd.clamp(start + 1, amps.length);
      final slice = amps.sublist(start, end);
      final average = slice.reduce((a, b) => a + b) / slice.length;
      result.add(average.clamp(0.08, 1.0));
    }
    return result;
  }
}
