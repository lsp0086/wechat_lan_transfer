// LocalSend v2 DTO 与文件工具纯函数单测。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wechat_lan_transfer/Transfer/file_utils.dart';
import 'package:wechat_lan_transfer/Transfer/ls_discovery.dart';
import 'package:wechat_lan_transfer/Transfer/ls_dto.dart';

void main() {
  group('LsDeviceDto', () {
    test('toJson 对齐官方 register JSON（camelCase，可空省略）', () {
      final dto = LsDeviceDto(
        alias: 'Secret Banana',
        fingerprint: 'abc123',
        port: 53317,
        deviceModel: 'macOS',
      );
      final json = dto.toJson();
      expect(json['alias'], 'Secret Banana');
      expect(json['version'], kLsProtocolVersion);
      expect(json['deviceModel'], 'macOS');
      expect(json.containsKey('deviceType'), isFalse);
      expect(json['fingerprint'], 'abc123');
      expect(json['port'], 53317);
      expect(json['protocol'], 'https');
      expect(json['download'], false);
    });

    test('fromJson roundtrip', () {
      const raw = '''{
        "alias": "Test Device",
        "version": "2.2",
        "deviceType": "desktop",
        "fingerprint": "fp",
        "port": 53317,
        "protocol": "https",
        "download": false
      }''';
      final dto = LsDeviceDto.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
      expect(dto.alias, 'Test Device');
      expect(dto.deviceType, 'desktop');
      expect(dto.port, 53317);
      expect(dto.download, false);
      expect(LsDeviceDto.fromJson(dto.toJson()).fingerprint, 'fp');
    });

    test('fromJson 缺省字段兜底', () {
      final dto = LsDeviceDto.fromJson(const {
        'alias': 'x',
        'fingerprint': 'f',
      });
      expect(dto.version, kLsProtocolVersion);
      expect(dto.port, kLsDefaultPort);
      expect(dto.protocol, 'https');
    });
  });

  group('LsFileDto', () {
    test('toJson 可空字段省略', () {
      const dto = LsFileDto(
        id: 'file1',
        fileName: 'test.png',
        size: 1024,
        fileType: 'image/png',
      );
      final json = dto.toJson();
      expect(json.containsKey('sha256'), isFalse);
      expect(json.containsKey('preview'), isFalse);
      expect(json.containsKey('metadata'), isFalse);
    });

    test('fromJson roundtrip', () {
      const dto = LsFileDto(
        id: 'f',
        fileName: 'a.txt',
        size: 3,
        fileType: 'text/plain',
        sha256: 'aa',
      );
      final back = LsFileDto.fromJson(dto.toJson());
      expect(back.id, 'f');
      expect(back.sha256, 'aa');
      expect(back.preview, isNull);
    });
  });

  group('LsPrepareUploadResponse', () {
    test('fromJson 解析 sessionId + token map', () {
      final res = LsPrepareUploadResponse.fromJson(const {
        'sessionId': 's1',
        'files': {'f1': 't1', 'f2': 't2'},
      });
      expect(res.sessionId, 's1');
      expect(res.files['f1'], 't1');
    });
  });

  group('LsSendError.fromStatus', () {
    test('官方状态码归类', () {
      expect(LsSendError.fromStatus(401, '').kind, LsErrorKind.pinRequired);
      expect(LsSendError.fromStatus(403, '').kind, LsErrorKind.rejected);
      expect(LsSendError.fromStatus(409, '').kind, LsErrorKind.busy);
      expect(LsSendError.fromStatus(429, '').kind, LsErrorKind.tooManyRequests);
      expect(
          LsSendError.fromStatus(422, '').kind, LsErrorKind.checksumMismatch);
      expect(LsSendError.fromStatus(500, '').kind, LsErrorKind.unknown);
    });
  });

  group('lsSanitizeFileName', () {
    test('路径穿越防护', () {
      expect(lsSanitizeFileName('../../etc/passwd'), 'passwd');
      expect(lsSanitizeFileName('..\\..\\win.ini'), 'win.ini');
      expect(lsSanitizeFileName('../..'), 'unnamed_file');
      expect(lsSanitizeFileName(''), 'unnamed_file');
      expect(lsSanitizeFileName('a/b/c.txt'), 'c.txt');
      expect(lsSanitizeFileName('bad<name>.txt'), 'bad_name_.txt');
    });

    test('控制字符清除与超长截断', () {
      expect(lsSanitizeFileName('a\x00b\x7Fc'), 'abc');
      final long = '${'x' * 300}.png';
      final out = lsSanitizeFileName(long);
      expect(out.length, lessThanOrEqualTo(200));
      expect(out.endsWith('.png'), isTrue);
    });
  });

  group('lsFitFileName', () {
    test('短名不截断', () {
      expect(lsFitFileName('hello.txt'), 'hello.txt');
    });

    test('超长中文名按字节截断并保留扩展名', () {
      final raw = '${'中' * 100}.jpg'; // 600 字节
      final out = lsFitFileName(raw, maxBytes: 60);
      expect(utf8.encode(out).length, lessThanOrEqualTo(60));
      expect(out.endsWith('.jpg'), isTrue);
      expect(out.contains('…'), isTrue);
    });
  });

  group('lsParseAnnounce', () {
    test('解析官方 announce 载荷（camelCase + announce 标志）', () {
      final device = lsParseAnnounce(const {
        'alias': 'Nice Orange',
        'version': '2.2',
        'deviceType': 'desktop',
        'fingerprint': 'ABC',
        'port': 53317,
        'protocol': 'https',
        'download': false,
        'announce': true,
      }, '192.168.1.5');
      expect(device, isNotNull);
      expect(device!.fingerprint, 'abc'); // 指纹统一小写
      expect(device.alias, 'Nice Orange');
      expect(device.ip, '192.168.1.5');
      expect(device.port, 53317);
      expect(device.version, '2.2');
      expect(device.download, isFalse);
    });

    test('缺 fingerprint / 端口非法返回 null', () {
      expect(lsParseAnnounce(const {'alias': 'x'}, '1.2.3.4'), isNull);
      expect(
        lsParseAnnounce(const {
          'alias': 'x',
          'fingerprint': 'f',
          'port': 99999,
        }, '1.2.3.4'),
        isNull,
      );
    });

    test('alias 空回退未知设备，port 缺省 53317', () {
      final device = lsParseAnnounce(const {'fingerprint': 'f'}, '1.2.3.4');
      expect(device!.alias, '未知设备');
      expect(device.port, kLsDefaultPort);
    });
  });

  group('lsBuildAnnounce', () {
    test('载荷 = 设备信息 + announce 标志', () {
      final payload = lsBuildAnnounce(const LsDeviceDto(
        alias: 'me',
        fingerprint: 'fp',
        port: 53317,
      ));
      expect(payload['announce'], isTrue);
      expect(payload['alias'], 'me');
      expect(payload['fingerprint'], 'fp');
      expect(payload['port'], 53317);
      expect(payload['protocol'], 'https');
    });
  });
}
