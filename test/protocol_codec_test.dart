import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wechat_lan_transfer/Services/device_key_resolver.dart';
import 'package:wechat_lan_transfer/Services/folder_archive_service.dart';
import 'package:wechat_lan_transfer/Services/media_type.dart';
import 'package:wechat_lan_transfer/Services/transfer_limits.dart';
import 'package:wechat_lan_transfer/Services/file_size_format.dart';
import 'package:wechat_lan_transfer/Services/free_space.dart';
import 'package:wechat_lan_transfer/Services/lan_discovery_service.dart';
import 'package:wechat_lan_transfer/Services/message_cache_service.dart';
import 'package:wechat_lan_transfer/Services/offline_text_queue.dart';
import 'package:wechat_lan_transfer/Services/session_tracker.dart';
import 'package:wechat_lan_transfer/Services/udp_port_probe.dart';
import 'package:wechat_lan_transfer/Services/storage_config.dart';
import 'package:wechat_lan_transfer/Services/lan_utils.dart';
import 'package:wechat_lan_transfer/Services/protocol_codec.dart';
import 'package:wechat_lan_transfer/Services/time_format.dart';
import 'package:wechat_lan_transfer/Services/transfer_texts.dart';
import 'package:wechat_lan_transfer/Services/launch_args.dart';
import 'package:wechat_lan_transfer/Services/device_sort.dart';
import 'package:wechat_lan_transfer/Services/audio_format.dart';
import 'package:wechat_lan_transfer/Services/bounded_cache.dart';
import 'package:wechat_lan_transfer/Services/transfer_id.dart';
import 'package:wechat_lan_transfer/Services/receive_dialog_texts.dart';
import 'package:wechat_lan_transfer/Services/announce_payload.dart';
import 'package:wechat_lan_transfer/Services/local_ip_picker.dart';
import 'package:wechat_lan_transfer/Services/extract_naming.dart';
import 'package:wechat_lan_transfer/Services/log.dart';
import 'package:wechat_lan_transfer/Services/history_paging.dart';
import 'package:wechat_lan_transfer/Services/text_edit.dart' hide isNotNull; // E1：避与matcher.isNotNull冲突
import 'package:wechat_lan_transfer/Services/send_path_classify.dart';
import 'package:wechat_lan_transfer/Services/resend_lookup.dart';
import 'package:wechat_lan_transfer/Services/text_inbound.dart';
import 'package:wechat_lan_transfer/Services/pending_dedup.dart';
import 'package:wechat_lan_transfer/Services/online_check.dart';
import 'package:wechat_lan_transfer/Services/file_icon.dart';
import 'package:wechat_lan_transfer/Services/share_classify.dart';
import 'package:wechat_lan_transfer/Services/message_actions.dart';
import 'package:wechat_lan_transfer/Services/transfer_state_map.dart';
import 'package:wechat_lan_transfer/Services/ack_decision.dart';
import 'package:wechat_lan_transfer/Services/cancel_texts.dart';
import 'package:wechat_lan_transfer/Services/peer_identity.dart';
import 'package:wechat_lan_transfer/Services/text_retry_policy.dart';
import 'package:wechat_lan_transfer/Services/bubble_meta.dart';
import 'package:wechat_lan_transfer/Services/send_naming.dart';
import 'package:wechat_lan_transfer/Services/send_waiting_texts.dart';
import 'package:wechat_lan_transfer/Services/media_layout.dart';
import 'package:wechat_lan_transfer/Services/device_lookup.dart';
import 'package:wechat_lan_transfer/Services/arrival_texts.dart';
import 'package:wechat_lan_transfer/Services/action_bubble_layout.dart';
import 'package:wechat_lan_transfer/Services/file_location_command.dart';
import 'package:wechat_lan_transfer/Services/blocked_list.dart';
import 'package:wechat_lan_transfer/Services/pick_classify.dart';
import 'package:wechat_lan_transfer/Services/device_merge.dart';
import 'package:wechat_lan_transfer/Services/device_tile_meta.dart';
import 'package:wechat_lan_transfer/Services/pin_texts.dart';
import 'package:wechat_lan_transfer/Model/chat_model.dart';
import 'package:wechat_lan_transfer/Services/audio_bubble_meta.dart';
import 'package:wechat_lan_transfer/Services/emoji_bubble_texts.dart';
import 'package:wechat_lan_transfer/Services/chat_list_texts.dart';
import 'package:wechat_lan_transfer/Services/message_factory.dart';
import 'package:wechat_lan_transfer/Services/record_policy.dart';
import 'package:wechat_lan_transfer/Services/chat_defaults.dart';
import 'package:wechat_lan_transfer/Services/chat_more_actions.dart';
import 'package:wechat_lan_transfer/Services/pairing_texts.dart';
import 'package:wechat_lan_transfer/Services/settings_texts.dart';
import 'package:wechat_lan_transfer/Services/chat_info_texts.dart';
import 'package:wechat_lan_transfer/Services/send_dispatch.dart';
import 'package:wechat_lan_transfer/Services/security_event.dart';
import 'package:wechat_lan_transfer/Services/text_send_queue.dart';
import 'package:wechat_lan_transfer/Services/image_existence_cache.dart';
import 'package:wechat_lan_transfer/Services/chat_recovery.dart';
import 'package:wechat_lan_transfer/Services/app_clock.dart' as app_clock;
import 'package:wechat_lan_transfer/Services/delay_policy.dart' as delay_policy;
import 'package:wechat_lan_transfer/Services/record_ui.dart';
import 'package:wechat_lan_transfer/Services/chat_debug_logs.dart';
import 'package:wechat_lan_transfer/Services/cache_crypto.dart';
import 'package:wechat_lan_transfer/Services/chat_list_logs.dart' as chat_list_logs;

void main() {
  group('header 编解码', () {
    test('encode/decode 往返一致', () {
      final (padded, lenBytes) = ProtocolCodec.encodeFileHeader({
        'fileName': '测试.txt',
        'fileSize': 123,
        'taskId': 't1',
      });
      expect(padded.length, 1024);
      expect(lenBytes.length, 4);
      final decoded = ProtocolCodec.decodeFileHeader([...padded, ...lenBytes]);
      expect(decoded['fileName'], '测试.txt');
      expect(decoded['fileSize'], 123);
    });

    test('超长头部抛错', () {
      expect(
        () => ProtocolCodec.encodeFileHeader({'fileName': 'a' * 2000}),
        throwsArgumentError,
      );
    });

    test('非法头长抛错', () {
      final bad = List<int>.filled(1028, 0);
      // 头长字段写一个超大值
      bad[1024] = 0x7F;
      expect(() => ProtocolCodec.decodeFileHeader(bad), throwsArgumentError);
    });
  });

  group('sanitize（P0-2 穿越拦截）', () {
    // 通过 header 往返验证清洗逻辑的输入边界
    test('../ 逃逸被截断为 basename', () {
      const raw = '../../etc/passwd';
      final name = raw.replaceAll('\\', '/').split('/').last;
      expect(name, 'passwd');
    });
  });

  group('握手 key', () {
    test('优先 transferId', () {
      expect(
        ProtocolCodec.handshakeKey(
          transferId: 'tr_1',
          ip: '192.168.1.2',
          fileName: 'a.txt',
        ),
        'tr_1',
      );
    });

    test('旧端回退 ip_filename', () {
      expect(
        ProtocolCodec.handshakeKey(ip: '192.168.1.2', fileName: 'a.txt'),
        '192.168.1.2_a.txt',
      );
    });
  });

  group('ACK 退避', () {
    test('指数增长 800/1600/3200/6400', () {
      expect(ProtocolCodec.ackBackoffMs(0), 800);
      expect(ProtocolCodec.ackBackoffMs(1), 1600);
      expect(ProtocolCodec.ackBackoffMs(2), 3200);
      expect(ProtocolCodec.ackBackoffMs(3), 6400);
    });
  });

  // E2 补单测
  group('E2 offset/sessionId 透传', () {
    test('encode 默认带 v/offset，decode 保留兼容', () {
      final (padded, lenBytes) = ProtocolCodec.encodeFileHeader({
        'fileName': 'a.bin',
        'fileSize': 10,
        'taskId': 't2',
        'sessionId': 's1',
        'offset': 123,
      });
      final decoded = ProtocolCodec.decodeFileHeader([...padded, ...lenBytes]);
      expect(decoded['v'], 1);
      expect(decoded['offset'], 123);
      expect(decoded['sessionId'], 's1');
    });

    test('旧端无 v 视为 1 兼容', () {
      final (padded, lenBytes) = ProtocolCodec.encodeFileHeader({
        'fileName': 'b.bin',
        'fileSize': 1,
        'taskId': 't3',
      });
      final decoded = ProtocolCodec.decodeFileHeader([...padded, ...lenBytes]);
      expect(decoded['v'], 1);
      expect(decoded['offset'], 0);
    });

    test('v>1 抛错提示升级', () {
      final (padded, lenBytes) = ProtocolCodec.encodeFileHeader({
        'fileName': 'c.bin',
        'fileSize': 1,
        'taskId': 't4',
        'v': 99,
      });
      expect(
        () => ProtocolCodec.decodeFileHeader([...padded, ...lenBytes]),
        throwsArgumentError,
      );
    });
  });

  group('E2 hmac 新鲜度', () {
    test('同 key 同载荷 hmac 一致，去掉 hmac 字段后可验', () {
      final payload = {'cmd': 'ping', 'ts': 123, 'nonce': 'n1'};
      final h1 = ProtocolCodec.hmacFor(payload, 'key1');
      final h2 = ProtocolCodec.hmacFor({...payload, 'hmac': 'x'}, 'key1');
      expect(h1, h2);
      expect(ProtocolCodec.hmacFor(payload, 'key2') == h1, false);
    });

    test('过期时间戳判旧', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      expect(ProtocolCodec.isTimestampFresh(now - 10 * 1000), true);
      expect(ProtocolCodec.isTimestampFresh(now - 500 * 1000), false);
      expect(ProtocolCodec.isFreshTimestamp(null), false);
    });
  });

  group('E2 handshakeKey', () {
    test('空 transferId 回退 ip_filename', () {
      expect(
        ProtocolCodec.handshakeKey(
          transferId: '',
          ip: '10.0.0.1',
          fileName: 'x.zip',
        ),
        '10.0.0.1_x.zip',
      );
    });
  });

  group('S1 verifyHmac', () {
    test('同载荷验签通过，篡改后失败', () {
      final payload = {'cmd': 'ping', 'ts': 123, 'nonce': 'n1'};
      final h = ProtocolCodec.hmacFor(payload, 'key1');
      expect(ProtocolCodec.verifyHmac({...payload, 'hmac': h}, 'key1'), true);
      expect(
        ProtocolCodec.verifyHmac({...payload, 'cmd': 'pong', 'hmac': h}, 'key1'),
        false,
      );
      expect(ProtocolCodec.verifyHmac(payload, 'key1'), false);
      expect(ProtocolCodec.verifyHmac({...payload, 'hmac': h}, ''), false);
    });

    test('newAuthToken 32 位 hex 且随机', () {
      final a = ProtocolCodec.newAuthToken();
      final b = ProtocolCodec.newAuthToken();
      expect(a.length, 32);
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(a), true);
      expect(a == b, false);
    });
  });

  group('E1 指纹键', () {
    test('64 位 hex 才算指纹', () {
      expect(LanUtils.isFingerprintKey('a' * 64), true);
      expect(LanUtils.isFingerprintKey('A' * 64), true);
      expect(LanUtils.isFingerprintKey('a' * 63), false);
      expect(LanUtils.isFingerprintKey('192.168.1.2'), false);
      expect(LanUtils.isFingerprintKey('g' * 64), false);
    });
  });

  group('E2 存储配置解析', () {
    test('空/损坏返回空配置', () {
      expect(StorageConfig.parse(null).udpPort, null);
      expect(StorageConfig.parse('').storagePath, null);
      expect(StorageConfig.parse('not json').tcpPort, null);
    });

    test('端口只接受 1024-65535', () {
      final ok = StorageConfig.parse(
        '{"storagePath":"/tmp","udpPort":9000,"tcpPort":9001}',
      );
      expect(ok.storagePath, '/tmp');
      expect(ok.udpPort, 9000);
      expect(ok.tcpPort, 9001);
      final bad = StorageConfig.parse('{"udpPort":80,"tcpPort":99999}');
      expect(bad.udpPort, null);
      expect(bad.tcpPort, null);
      expect(bad.storagePath, null);
    });
  });

  group('E1 会话决策', () {
    test('一次同意/拒绝管整批，超限清空', () {
      final t = SessionTracker(capacity: 2);
      t.remember('s1', true);
      t.remember('s2', false);
      expect(t.isAccepted('s1'), true);
      expect(t.isRejected('s2'), true);
      expect(t.isAccepted('s3'), false);
      expect(t.isRejected(null), false);
      // 同意/拒绝各管各的上限：再记两个同意才触发同意集合清空
      t.remember('s3', true);
      t.remember('s4', true);
      expect(t.isAccepted('s1'), false);
      expect(t.isAccepted('s4'), true);
      expect(t.isRejected('s2'), true);
    });

    test('重复 accept 防护 add/contains/remove', () {
      final g = AutoAcceptedGuard();
      expect(g.contains('tr1'), false);
      g.add('tr1');
      expect(g.contains('tr1'), true);
      g.remove('tr1');
      expect(g.contains('tr1'), false);
      g.remove(null);
      g.remove('');
    });
  });

  group('E1 网络工具', () {
    test('归一化去括号scope小写', () {
      expect(LanUtils.normalizeIp('[FD00::1%eth0]'), 'fd00::1');
      expect(LanUtils.normalizeIp(' 192.168.1.2 '), '192.168.1.2');
    });

    test('私有v4/v6与回环判定', () {
      expect(LanUtils.isPrivateIP('192.168.1.2'), true);
      expect(LanUtils.isPrivateIP('10.0.0.1'), true);
      expect(LanUtils.isPrivateIP('172.16.0.1'), true);
      expect(LanUtils.isPrivateIP('172.32.0.1'), false);
      expect(LanUtils.isPrivateIP('8.8.8.8'), false);
      expect(LanUtils.isPrivateIP('fe80::1'), true);
      expect(LanUtils.isPrivateIP('fd00::1'), true);
      expect(LanUtils.isPrivateIP('2001:db8::1'), false);
      expect(LanUtils.isLoopback('127.0.0.1'), true);
      expect(LanUtils.isLoopback('::1'), true);
      expect(LanUtils.isLoopback('192.168.1.2'), false);
    });

    test('legacy 广播地址回退 /24', () {
      expect(LanUtils.legacySubnetBroadcast('192.168.1.2'), '192.168.1.255');
      expect(LanUtils.legacySubnetBroadcast('bad'), null);
    });

    test('UDP 端口探测 v4回退v6与全败抛错', () async {
      // v4 全败、v6 成功
      final s6 = await probeUdpPort<int>(
        9000,
        (addr, port) async {
          if (addr.type == InternetAddressType.IPv4) {
            throw SocketException('busy');
          }
          return port;
        },
      );
      expect(s6, 9000);
      // 首个 v4 成功
      final s4 = await probeUdpPort<int>(9000, (addr, port) async => port);
      expect(s4, 9000);
      // 全败抛最后错误
      await expectLater(
        probeUdpPort<int>(
          9000,
          (addr, port) async => throw SocketException('busy'),
        ),
        throwsA(isA<SocketException>()),
      );
      // 端口上限截断：65530..65535 共 6 个候选；每候选 v4+v6 各调一次 binder
      var called = 0;
      await expectLater(
        probeUdpPort<int>(
          65530,
          (addr, port) async {
            called++;
            throw SocketException('busy');
          },
          attempts: 10,
        ),
        throwsA(isA<SocketException>()),
      );
      expect(called, 12);
    });
  });

  group('E1 相对时间', () {

    test('分钟/小时/天/日期', () {
      final now = DateTime(2026, 10, 6, 12);
      expect(formatLastSeen(now.subtract(const Duration(seconds: 20)), now: now), '刚刚');
      expect(formatLastSeen(now.subtract(const Duration(minutes: 5)), now: now), '5分钟前');
      expect(formatLastSeen(now.subtract(const Duration(hours: 3)), now: now), '3小时前');
      expect(formatLastSeen(now.subtract(const Duration(days: 2)), now: now), '2天前');
      expect(
        formatLastSeen(DateTime(2026, 9, 1), now: now),
        '9/1',
      );
    });
  });

  group('U5 十进制文件大小', () {
    test('B/KB/MB/GB 十进制', () {
      expect(formatFileSize(0), '0 B');
      expect(formatFileSize(999), '999 B');
      expect(formatFileSize(1500), '1.5 KB');
      expect(formatFileSize(2500000), '2.50 MB');
      expect(formatFileSize(3000000000), '3.00 GB');
    });
  });

  group('E1 去重窗口', () {
    test('首次放行重复拦截，TTL过期后放行', () {
      final w = RecvDedupWindow(ttl: const Duration(seconds: 30));
      final t0 = DateTime(2026, 10, 6, 12);
      expect(w.isDuplicate('m1', now: t0), false);
      expect(w.isDuplicate('m1', now: t0), true);
      expect(
        w.isDuplicate('m1', now: t0.add(const Duration(seconds: 31))),
        false,
      );
    });

    test('待办键 transferId 优先旧端回退', () {
      expect(pendingMetaKey('t1', '1.2.3.4', 'a.txt'), 't1');
      expect(pendingMetaKey(null, '1.2.3.4', 'a.txt'), '1.2.3.4_a.txt');
      expect(pendingMetaKey('', '1.2.3.4', 'a.txt'), '1.2.3.4_a.txt');
      expect(pendingAcceptKey('t1', 'a.txt'), 't1');
      expect(pendingAcceptKey(null, 'a.txt'), 'a.txt');
      expect(pendingTimerKey('t1', 'fb'), 't1');
      expect(pendingTimerKey(null, 'fb'), 'fb');
      expect(pendingMessageId('t1', 'a.txt'), 'pending_t1');
      expect(
        pendingMessageId(null, 'a.txt', nowMicros: 123),
        'pending_123_${'a.txt'.hashCode.abs() % (1 << 32)}',
      );
      expect(
        pendingTransferMatches(
          messageTransferId: 't1',
          messageFileName: 'x',
          transferId: 't1',
          fileName: 'a.txt',
        ),
        true,
      );
      expect(
        pendingTransferMatches(
          messageTransferId: 't2',
          messageFileName: 'a.txt',
          transferId: 't1',
          fileName: 'a.txt',
        ),
        false,
      );
      expect(
        pendingTransferMatches(
          messageTransferId: null,
          messageFileName: 'a.txt',
          transferId: null,
          fileName: 'a.txt',
        ),
        true,
      );
    });

    test('PIN 限流超限静默成功重置', () {
      final l = PinFailLimiter(maxFails: 2);
      expect(l.noteFailure('1.1.1.1'), 1);
      expect(l.overLimit('1.1.1.1'), false);
      expect(l.noteFailure('1.1.1.1'), 2);
      expect(l.overLimit('1.1.1.1'), false);
      expect(l.noteFailure('1.1.1.1'), 3);
      expect(l.overLimit('1.1.1.1'), true);
      l.reset('1.1.1.1');
      expect(l.overLimit('1.1.1.1'), false);
    });

    test('离线队列幂等入队移除清空', () {
      final q = OfflineTextQueue();
      q.enqueue('d1', 'm1', 'hi');
      q.enqueue('d1', 'm1', 'hi');
      expect(q.lengthOf('d1'), 1);
      q.enqueue('d1', 'm2', 'hello');
      expect(q.lengthOf('d1'), 2);
      final item = q.items('d1')!.first;
      q.removeItem('d1', item);
      expect(q.lengthOf('d1'), 1);
      q.removeItem('d1', q.items('d1')!.first);
      expect(q.isEmpty, true);
      expect(q.items('d1'), null);
    });

    test('身份键解析 deviceId 优先旧端回退', () {
      expect(deviceIdFromPayload({'deviceId': 'fp1'}), 'fp1');
      expect(deviceIdFromPayload({'tlsFp': 'fp2'}), 'fp2');
      expect(deviceIdFromPayload(null), '');
      expect(
        resolveDeviceIp(deviceKey: 'fp1', currentIp: '1.2.3.4'),
        '1.2.3.4',
      );
      expect(resolveDeviceIp(deviceKey: '1.2.3.4'), '1.2.3.4');
      expect(isBlockedEntry({'1.2.3.4'}, '1.2.3.4', null), true);
      expect(isBlockedEntry({'fp1'}, '1.2.3.4', 'fp1'), true);
      expect(isBlockedEntry({'fp1'}, '1.2.3.4', null), false);
    });

    test('手动同意一次消费', () {
      final s = ManualAcceptStore();
      expect(s.take('d1', 't1'), false);
      s.add('d1', 't1');
      expect(s.take('d1', 't1'), true);
      expect(s.take('d1', 't1'), false);
    });

    test('待办元数据存取回退', () {
      final m = PendingFileMeta();
      m.put('t1', {'sessionId': 's1', 'fileSize': 100});
      expect(m.sessionOf('t1'), 's1');
      expect(m.sizeOf('t1'), 100);
      expect(m.sizeOf('missing'), 0);
      expect(m.takeByTransferId('t1', 'fb'), isNotNull);
      m.put('fb', {'fileSize': 7});
      expect(m.takeByTransferId(null, 'fb')?['fileSize'], 7);
      expect(m.takeByTransferId('nope', 'missing'), null);
    });

    test('ETA null负数隐藏分秒格式', () {
      expect(formatEta(null), null);
      expect(formatEta(-1), null);
      expect(formatEta(5), '5秒');
      expect(formatEta(75), '1分15秒');
    });

    test('唯一短ID前缀微秒盐', () {
      final a = newUniqueShortId('tr', nowMicros: 1, rand: 2);
      final b = newUniqueShortId('tr', nowMicros: 1, rand: 2);
      expect(a, 'tr_1_2');
      expect(a, b);
      expect(newUniqueShortId('ss', nowMicros: 1, rand: 3), 'ss_1_3');
      expect(newUniqueShortId('tr').startsWith('tr_'), true);
    });

    test('图片后缀统一大小写无扩展名（mime 新库 + 回退表）', () {
      expect(isImageFileName('a.JPG'), true);
      expect(isImageFileName('a.heic'), true);
      expect(isImageFileName('a.svg'), true);
      expect(isImageFileName('a.txt'), false);
      expect(isImageFileName('noext'), false);
      // mime 覆盖的新后缀同样命中
      expect(isImageFileName('a.tiff'), true);
      expect(isImageFileName('a.ico'), true);
    });

    test('批量序号后缀仅批量展示', () {
      expect(batchCountSuffix(null, 3, 0), '');
      expect(batchCountSuffix('s', 1, 0), '');
      expect(batchCountSuffix('s', 3, 0), ' (1/3)');
      expect(batchCountSuffix('s', 3, 2), ' (3/3)');
    });

    test('取消匹配精确ID优先文件名限状态', () {
      bool hit({
        String? mt,
        String? mk,
        String? mf,
        required bool active,
        String? t,
        String? k,
        required String f,
      }) =>
          pendingFileCancelMatches(
            messageTransferId: mt,
            messageTaskId: mk,
            messageFileName: mf,
            messageActive: active,
            transferId: t,
            taskId: k,
            fileName: f,
          );
      expect(hit(mt: 't1', active: false, t: 't1', f: 'a'), true);
      expect(hit(mk: 'k1', active: false, k: 'k1', f: 'a'), true);
      expect(hit(mf: 'a', active: true, f: 'a'), true);
      expect(hit(mf: 'a', active: false, f: 'a'), false);
      expect(hit(mf: 'b', active: true, f: 'a'), false);
    });
  });

  group('S5 文字加密往返', () {
    test('双方指纹派生相同密钥且与顺序无关', () {
      final a = List.filled(64, 'a').join();
      final b = List.filled(64, 'b').join();
      final k1 = ProtocolCodec.deriveTextSharedKey(a, b);
      final k2 = ProtocolCodec.deriveTextSharedKey(b, a);
      expect(k1.isNotEmpty, true);
      expect(k1, k2);
      expect(ProtocolCodec.deriveTextSharedKey('', b), '');
    });

    test('加密后可解密，篡改后失败', () {
      final a = List.filled(64, 'c').join();
      final b = List.filled(64, 'd').join();
      final key = ProtocolCodec.deriveTextSharedKey(a, b);
      final cipher = ProtocolCodec.encryptText('你好，局域网！', key);
      expect(cipher.isNotEmpty, true);
      expect(ProtocolCodec.decryptText(cipher, key), '你好，局域网！');
      // 篡改最后一个字符（tag 区），解密应失败。
      final tampered = cipher.substring(0, cipher.length - 1) +
          (cipher.endsWith('A') ? 'B' : 'A');
      expect(ProtocolCodec.decryptText(tampered, key), null);
      expect(ProtocolCodec.decryptText(cipher, 'wrong-key'), null);
    });
  });

  group('广播身份解析（E1 resolveBroadcastIdentity）', () {
    test('deviceId 优先作身份键，rawId 作路由 IP', () {
      final r = resolveBroadcastIdentity({
        'id': '192.168.1.5',
        'senderIp': '192.168.1.5',
        'deviceId': 'f' * 64,
      }, '192.168.1.5');
      expect(r, isNotNull);
      expect(r!.ip, '192.168.1.5');
      expect(r.deviceKey, 'f' * 64);
    });

    test('rawId 为 0.0.0.0 回退来源 IP，无 deviceId 回退 IP 键', () {
      final r = resolveBroadcastIdentity({
        'id': '0.0.0.0',
        'senderIp': '192.168.1.5',
      }, '192.168.1.9');
      expect(r!.ip, '192.168.1.9');
      expect(r.deviceKey, '192.168.1.9');
    });

    test('来源 IP 无效时回退 payload.senderIp', () {
      final r = resolveBroadcastIdentity({
        'id': '0.0.0.0',
        'senderIp': '192.168.1.5',
      }, '0.0.0.0');
      expect(r!.ip, '192.168.1.5');
    });

    test('三者均无效 → null 丢弃', () {
      final r = resolveBroadcastIdentity({'id': '0.0.0.0', 'senderIp': ''}, '');
      expect(r, isNull);
    });

    test('rawId 正常且无 deviceId/senderIp → 用 rawId', () {
      final r = resolveBroadcastIdentity({'id': '192.168.1.7'}, '');
      expect(r!.ip, '192.168.1.7');
      expect(r.deviceKey, '192.168.1.7');
    });
  });

  group('文件夹打包/zip 安全（E1 folder_archive_service）', () {
    test('safeZipEntryPath：../ 逃逸与 ./ 归一化清洗', () {
      expect(
        FolderArchiveService.safeZipEntryPath('../../etc/passwd'),
        'etc/passwd',
      );
      expect(FolderArchiveService.safeZipEntryPath('a/../../b.txt'), 'b.txt');
      expect(FolderArchiveService.safeZipEntryPath('a/./b/./c.txt'), 'a/b/c.txt');
      expect(FolderArchiveService.safeZipEntryPath('\\a\\b.txt'), 'a/b.txt');
      expect(FolderArchiveService.safeZipEntryPath('/abs/path.txt'), 'abs/path.txt');
      expect(FolderArchiveService.safeZipEntryPath('..'), '');
      expect(FolderArchiveService.safeZipEntryPath('a/../../../..'), '');
      expect(FolderArchiveService.safeZipEntryPath('a/./../'), '');
    });

    test('safeZipEntryPath：剥离顶层共同前缀（只剥一次）', () {
      expect(
        FolderArchiveService.safeZipEntryPath(
          'folder/sub/file.txt',
          commonPrefix: 'folder',
        ),
        'sub/file.txt',
      );
      expect(
        FolderArchiveService.safeZipEntryPath(
          'folder/folder2/file.txt',
          commonPrefix: 'folder',
        ),
        'folder2/file.txt',
      );
      expect(
        FolderArchiveService.safeZipEntryPath(
          'other/file.txt',
          commonPrefix: 'folder',
        ),
        'other/file.txt',
      );
    });

    test('commonTopPrefix：全部共享返回前缀，含散文件返回 null', () {
      expect(
        FolderArchiveService.commonTopPrefix([
          'f/a.txt',
          'f/b.txt',
          'f/sub/c.txt',
        ]),
        'f',
      );
      expect(FolderArchiveService.commonTopPrefix(['f/a.txt', 'b.txt']), null);
      expect(FolderArchiveService.commonTopPrefix(['a.txt']), null);
      expect(FolderArchiveService.commonTopPrefix(const []), null);
    });

    test('parseEndpoint：IPv4:端口 / 缺省端口 / 非法输入', () {
      final r = LanUtils.parseEndpoint('192.168.1.10:8888');
      expect(r, isNotNull);
      expect(r!.ip, '192.168.1.10');
      expect(r.port, 8888);

      final r2 = LanUtils.parseEndpoint('192.168.1.10', defaultPort: 9000);
      expect(r2!.port, 9000);

      // IPv6 方括号 + 端口
      final r3 = LanUtils.parseEndpoint('[fe80::1]:9001');
      expect(r3!.ip, 'fe80::1');
      expect(r3.port, 9001);

      // 裸 IPv6（多冒号）无端口整体当 IP
      final r4 = LanUtils.parseEndpoint('fe80::1%eth0');
      expect(r4!.ip, 'fe80::1');
      expect(r4.port, 8888);

      // 非法输入
      expect(LanUtils.parseEndpoint('not an ip'), null);
      expect(LanUtils.parseEndpoint(''), null);
      expect(LanUtils.parseEndpoint('999.999.1.1'), null);
    });

    test('checkFolderPackable：空目录拒绝', () async {
      final dir = await Directory.systemTemp.createTemp('wlt_pack');
      try {
        final r = await FolderArchiveService.checkFolderPackable(dir);
        expect(r.ok, false);
        expect(r.message, '所选文件夹为空');
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('checkFolderPackable：正常目录通过 + 单文件超限拒绝', () async {
      final dir = await Directory.systemTemp.createTemp('wlt_pack');
      try {
        await File('${dir.path}/a.txt').writeAsString('hello');
        await Directory('${dir.path}/sub').create();
        await File('${dir.path}/sub/b.txt').writeAsString('world');
        final r = await FolderArchiveService.checkFolderPackable(dir);
        expect(r.ok, true);

        await File('${dir.path}/big.bin').writeAsBytes(List.filled(300, 0));
        final r2 = await FolderArchiveService.checkFolderPackable(
          dir,
          limits: const FolderArchiveLimits(maxPackSingleFile: 200),
        );
        expect(r2.ok, false);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('addDirectoryToArchive：打包往返（子目录 + 空目录保留）', () async {
      final dir = await Directory.systemTemp.createTemp('wlt_pack');
      try {
        await File('${dir.path}/a.txt').writeAsString('hello');
        final sub = Directory('${dir.path}/sub');
        await sub.create();
        await File('${sub.path}/b.txt').writeAsString('world');
        await Directory('${sub.path}/empty').create();

        final archive = Archive();
        await FolderArchiveService.addDirectoryToArchive(archive, dir, 'root');
        final zipBytes = ZipEncoder().encode(archive);
        final decoded = ZipDecoder().decodeBytes(zipBytes);
        final names = decoded.files.map((f) => f.name).toSet();
        expect(names.contains('root/a.txt'), true);
        expect(names.contains('root/sub/b.txt'), true);
        expect(names.contains('root/sub/empty/'), true);

        // 解码侧前缀检测 + 路径清洗（接收端解压链路同款纯函数）
        final common = FolderArchiveService.commonTopPrefix(
          decoded.files.where((f) => f.isFile).map((f) => f.name),
        );
        expect(common, 'root');
        expect(
          FolderArchiveService.safeZipEntryPath(
            'root/sub/b.txt',
            commonPrefix: common,
          ),
          'sub/b.txt',
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('LanDiscoveryService（E1 发现机器，回环集成）', () {
    test('绑定探测 / 单播收发 / 停止生命周期', () async {
      final a = LanDiscoveryService();
      final b = LanDiscoveryService();
      final waiter = StreamController<Map<String, dynamic>>.broadcast();
      // 用非常规端口，避免与本机其他服务冲突
      await b.start(
        preferredPort: 18996,
        localIPs: const [],
        onDatagram: (raw, ip, port) {
          waiter.add(jsonDecode(raw) as Map<String, dynamic>);
        },
      );
      await a.start(
        preferredPort: 18995,
        localIPs: const [],
        onDatagram: (raw, ip, port) {},
      );
      expect(a.udpPort, 18995);
      expect(b.udpPort, 18996);
      expect(a.isReady, true);
      expect(b.isReady, true);

      // 单播 sendTo：A → B（回环可靠，v4/v6 共用 handler）
      final sent = a.sendTo(
        utf8.encode(jsonEncode({'cmd': 'iamalive', 'id': 'u1'})),
        '127.0.0.1',
        b.udpPort,
      );
      expect(sent, true);
      final first = await waiter.stream.first.timeout(
        const Duration(seconds: 3),
      );
      expect(first['id'], 'u1');

      // 停止后 socket 释放，sendTo 返回 false；重复 stop 安全
      a.stop();
      expect(a.isReady, false);
      expect(a.sendTo(utf8.encode('{}'), '127.0.0.1', b.udpPort), false);
      a.stop();

      // broadcast() 可用（不抛错；广播路由依赖环境，不做送达断言）
      b.broadcast(
        utf8.encode(jsonEncode({'cmd': 'iamalive'})),
        [b.udpPort],
        const [],
      );
      b.stop();
      expect(b.isReady, false);
      await waiter.close();
    });
  });

  group('U2 启动参数（launch_args）', () {
    test('裸路径/--send/file:// 过滤与存在校验', () async {
      final dir = await Directory.systemTemp.createTemp('wlt_launch');
      try {
        final f = File('${dir.path}/x.txt');
        await f.writeAsString('hi');
        final missing = '${dir.path}/nope.txt';
        final got = LaunchArgs.pendingPaths([
          '--send',
          f.path,
          missing,
          '--verbose',
          'file://${f.path}',
        ]);
        expect(got, [f.path, f.path]);
        expect(LaunchArgs.pendingPaths([]), isEmpty);
        expect(LaunchArgs.pendingPaths(['--dart-entrypoint-args', '--x']), isEmpty);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('T4 分区剩余空间（free_space）', () {
    test('df -k -P 输出解析（Linux 6 列 + macOS 行尾挂载点）', () {
      const linuxOut = 'Filesystem     1024-blocks      Used Available Capacity '
          'Mounted on\n/dev/sda1         500000000 100000000 400000000      20% /';
      expect(
        FreeSpace.parseDfOutput(linuxOut, '/'),
        400000000 * 1024,
      );

      const macOut = 'Filesystem   1024-blocks      Used Available Capacity '
          'iused ifree %iused  Mounted on\n/dev/disk3s1s1   478891008 12000000 '
          '466891008     3%      0     0     0   /\n'
          '/dev/disk3s5      478891008 20000000 458891008     4% 500000 '
          '0     0   /System/Volumes/Data';
      // 目标行匹配：含路径的行优先
      expect(
        FreeSpace.parseDfOutput(macOut, '/System/Volumes/Data'),
        458891008 * 1024,
      );
      expect(FreeSpace.parseDfOutput(macOut, '/'), 466891008 * 1024);

      // 无第二行 / 列数不足 → null
      expect(FreeSpace.parseDfOutput('Filesystem blocks', '/'), null);
      expect(FreeSpace.parseDfOutput('', '/'), null);
    });

    test('driveOf：Windows 盘符提取', () {
      expect(FreeSpace.driveOf('C:\\Users\\test'), 'C:');
      expect(FreeSpace.driveOf('C:/Users/test'), 'C:');
      expect(FreeSpace.driveOf('/Users/test'), null);
      expect(FreeSpace.driveOf('relative/path'), null);
    });

    test('of：本机临时目录返回正值（macOS/Linux 走 df）', () async {
      final dir = await Directory.systemTemp.createTemp('wlt_space');
      try {
        final free = await FreeSpace.of(dir.path);
        expect(free, isNotNull);
        expect(free! > 0, true);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('parseBavail：statvfs 缓冲按指针宽度读 f_bavail（Android FFI）', () {
      // LP64（arm64-v8a/x86_64）：偏移 32 宽 8，little-endian
      final buf64 = Uint8List(112); // bionic LP64 结构体实长 112B
      ByteData.sublistView(buf64).setUint64(32, 1234567890123, Endian.little);
      expect(FreeSpace.parseBavail(buf64, 8), 1234567890123);

      // LP32（armeabi-v7a/x86）：偏移 16 宽 4
      final buf32 = Uint8List(68); // bionic LP32 结构体实长 68B
      ByteData.sublistView(buf32).setUint32(16, 3210987654, Endian.little);
      expect(FreeSpace.parseBavail(buf32, 4), 3210987654);

      // 异常钳制：全零（free=0）与超过 2^47（布局错位）→ null
      expect(FreeSpace.parseBavail(Uint8List(112), 8), null);
      ByteData.sublistView(buf64).setUint64(32, 1 << 48, Endian.little);
      expect(FreeSpace.parseBavail(buf64, 8), null);
      // 缓冲过短（越界）→ null
      expect(FreeSpace.parseBavail(Uint8List(8), 8), null);
    });
  });

  group('MessageCacheService（E3 sqlite 后端）', () {
    late Directory dir;
    late MessageCacheService cache;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('wlt_cache');
      cache = MessageCacheService.forTest(dir.path);
    });

    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    ChatMessage msg(String id, {String content = 'hi'}) => ChatMessage(
      id: id,
      senderId: '192.168.1.5',
      content: content,
      type: MessageType.text,
      timestamp: DateTime.now(),
      isMe: false,
    );

    test('append → flush → 新实例冷启动读取（sqlite 持久化）', () async {
      await cache.appendMessage('dev1', msg('m1'));
      await cache.flushPending();
      final cache2 = MessageCacheService.forTest(dir.path);
      final loaded = await cache2.loadMessages('dev1');
      expect(loaded.length, 1);
      expect(loaded.first.id, 'm1');
    });

    test('append 幂等跳过 + update 覆盖', () async {
      await cache.appendMessage('dev1', msg('m1'));
      await cache.appendMessage('dev1', msg('m1', content: 'dup'));
      await cache.updateMessage('dev1', 'm1', msg('m1', content: 'updated'));
      await cache.flushPending();
      final loaded = await cache.loadMessages('dev1');
      expect(loaded.length, 1);
      expect(loaded.first.content, 'updated');
    });

    test('上限裁剪 2000 条', () async {
      for (var i = 0; i < 2050; i++) {
        await cache.appendMessage('dev1', msg('m$i'));
      }
      await cache.flushPending();
      final loaded = await cache.loadMessages('dev1');
      expect(loaded.length, 2000);
      expect(loaded.first.id, 'm50');
      expect(loaded.last.id, 'm2049');
    });

    test('clearMessages / clearAllMessages', () async {
      await cache.appendMessage('dev1', msg('m1'));
      await cache.appendMessage('dev2', msg('m2'));
      await cache.flushPending();
      await cache.clearMessages('dev1');
      expect((await cache.loadMessages('dev1')).length, 0);
      expect((await cache.loadMessages('dev2')).length, 1);
      await cache.clearAllMessages();
      expect((await cache.loadMessages('dev2')).length, 0);
    });

    test('旧 JSON 文件一次性导入 sqlite（v4 IP 键反解 + 64hex 键）+ 删源', () async {
      final legacyV4 = File('${dir.path}/192_168_1_5_messages.json');
      await legacyV4.writeAsString(
        jsonEncode([msg('lm1').toJson(), msg('lm2').toJson()]),
      );
      final legacyHex = File('${dir.path}/${'a' * 64}_messages.json');
      await legacyHex.writeAsString(jsonEncode([msg('lm3').toJson()]));
      // v6/不可逆名保留 JSON（运行时 P0-7 迁移后再导）
      final legacyV6 = File('${dir.path}/fe80__1_messages.json');
      await legacyV6.writeAsString(jsonEncode([msg('lm4').toJson()]));

      final loaded = await cache.loadMessages('192.168.1.5');
      expect(loaded.length, 2);
      expect((await cache.loadMessages('a' * 64)).length, 1);
      expect(await legacyV4.exists(), false);
      expect(await legacyHex.exists(), false);
      expect(await legacyV6.exists(), true);
    });

    test('migrateLegacyCache：sqlite 行迁移（旧键 → 新键）', () async {
      await cache.appendMessage('192.168.1.5', msg('mm1'));
      await cache.flushPending();
      await cache.migrateLegacyCache('devX', '192.168.1.5');
      final loaded = await cache.loadMessages('devX');
      expect(loaded.length, 1);
      expect(loaded.first.id, 'mm1');
      expect((await cache.loadMessages('192.168.1.5')).length, 0);
    });
  });

  group('E1 设备排序（device_sort）', () {
    test('在线优先 + 按名排序，不改原列表', () {
      final devices = [
        (id: 'b', name: 'Zebra'),
        (id: 'a', name: 'Apple'),
        (id: 'c', name: 'Mango'),
      ];
      final sorted = sortDevicesOnlineFirst(
        devices: devices,
        idOf: (d) => d.id,
        nameOf: (d) => d.name,
        onlineIds: {'c', 'a'},
      );
      expect(sorted.map((d) => d.id).toList(), ['a', 'c', 'b']);
      expect(devices.first.id, 'b');
      final allOffline = sortDevicesOnlineFirst(
        devices: devices,
        idOf: (d) => d.id,
        nameOf: (d) => d.name,
        onlineIds: const {},
      );
      expect(allOffline.map((d) => d.id).toList(), ['a', 'c', 'b']);
    });
  });

  group('E1 音频格式（audio_format）', () {
    test('formatRecordDuration：秒/分秒', () {
      expect(formatRecordDuration(9000), '9\u2033');
      expect(formatRecordDuration(75000), '1\u203215\u2033');
      expect(formatRecordDuration(125000), '2\u203205\u2033');
    });

    test('encodeWaveformFromAmps：空输入占位 + 非空 clamping', () {
      final empty = jsonDecode(encodeWaveformFromAmps(const [])) as List;
      expect(empty.length, 25);
      expect(empty.every((e) => e == 0.15), true);
      final shaped = jsonDecode(encodeWaveformFromAmps([0.0, 2.0, 0.5]));
      expect(shaped.length, 25);
      expect(
        (shaped as List).every((e) => e >= 0.08 && e <= 1.0),
        true,
      );
    });
  });

  group('E1 有界缓存（bounded_cache）', () {
    test('超上限删一半 + Map 版原地裁剪', () {
      final c = BoundedCache<int>(capacity: 4);
      for (var i = 0; i < 6; i++) {
        c.put('k$i', i);
      }
      expect(c.entries.length <= 4, true);
      expect(c.get('k5'), 5);
      final m = <String, int>{
        for (var i = 0; i < 6; i++) 'k$i': i,
      };
      trimMapCache(m, capacity: 4);
      expect(m.length <= 4, true);
      expect(m.containsKey('k5'), true);
    });
  });

  group('E1 传输 ID 工厂（transfer_id + uuid 新库）', () {
    test('uuid v4 格式 + 唯一', () {
      final f = TransferIdFactory();
      final a = f.newTransferId();
      final b = f.newTransferId();
      final s = f.newSessionId();
      final uuidRe = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      expect(uuidRe.hasMatch(a), true);
      expect(uuidRe.hasMatch(s), true);
      expect(a == b, false);
    });
  });

  group('E1 接收对话框纯文案（receive_dialog_texts）', () {
    test('批量标题/文件名行/判定', () {
      expect(receiveDialogTitle('📁', 's1', 3), '📁 批量传输请求（共 3 个）');
      expect(receiveDialogTitle('📥', null, null), '📥 传输请求');
      expect(receiveDialogTitle('📥', 's1', 1), '📥 传输请求');
      expect(receiveDialogFileLine('a.zip', 's1', 3), 'a.zip 等 3 个文件');
      expect(receiveDialogFileLine('a.zip', null, null), 'a.zip');
      expect(isBatchReceive('s1', 3), true);
      expect(isBatchReceive('s1', 1), false);
      expect(isBatchReceive(null, 3), false);
    });

    test('TransferTexts.sendFailure：拒绝原因分支 + 超时', () {
      expect(
        TransferTexts.sendFailure(
          errLabel: '📤',
          displayName: 'a.txt',
          rejected: true,
          reason: 'pinWrong',
        ),
        '📤 对方已拒绝: a.txt（PIN 错误）',
      );
      expect(
        TransferTexts.sendFailure(
          errLabel: '📤',
          displayName: 'a.txt',
          rejected: true,
          reason: 'noSpace',
        ),
        '📤 对方空间不足: a.txt',
      );
      expect(
        TransferTexts.sendFailure(
          errLabel: '📤',
          displayName: 'a.txt',
          rejected: true,
          reason: 'blocked',
        ),
        '📤 对方已拒绝: a.txt',
      );
      expect(
        TransferTexts.sendFailure(
          errLabel: '📁',
          displayName: 'docs',
          rejected: false,
        ),
        '📁 等待超时: docs（对方稍后同意可继续接收）',
      );
      expect(TransferTexts.truncateError(Exception('x' * 200)).length, 100);
      expect(TransferTexts.truncateError('short'), 'short');
    });
  });

  group('E1 上线宣告载荷（announce_payload）', () {
    test('announceTargetPorts：默认端口探测范围 ∪ 本端端口，去重升序', () {
      // 本端在默认端口：8888..8897 + 8888 → 10 个
      expect(
        announceTargetPorts(8888, 8888),
        List.generate(10, (i) => 8888 + i),
      );
      // 本端回退到 8890：8888..8897 ∪ {8890} → 去重后仍 10 个
      expect(
        announceTargetPorts(8888, 8890),
        List.generate(10, (i) => 8888 + i),
      );
      // 本端在探测范围外（配置改端口 9999）：∪ {9999} 共 11 个
      expect(
        announceTargetPorts(8888, 9999),
        [...List.generate(10, (i) => 8888 + i), 9999],
      );
      // attempts 收窄
      expect(announceTargetPorts(100, 100, attempts: 2), [100, 101]);
    });

    test('组装字段 + 空 deviceId 不带 + 端口回退', () {
      final full = buildAnnouncePayload(
        localIp: '192.168.1.2',
        deviceName: 'Pixel',
        deviceType: 'mobile',
        cmd: 'iamalive',
        deviceId: 'f' * 64,
        udpPort: 8888,
        tcpPort: 8899,
      );
      expect(full['id'], '192.168.1.2');
      expect(full['cmd'], 'iamalive');
      expect(full['deviceId'], 'f' * 64);
      expect(full['udpPort'], 8888);
      final bare = buildAnnouncePayload(
        localIp: '192.168.1.2',
        deviceName: 'PC',
        deviceType: 'desktop',
        cmd: 'i_see_you',
        deviceId: '',
        udpPort: 8888,
        tcpPort: 8899,
      );
      expect(bare.containsKey('deviceId'), false);
      expect(bare['cmd'], 'i_see_you');
    });

    test('可见性门控：隐身跳过 + 仅配对档低频', () {
      expect(
        shouldSkipBroadcast(visibility: 'stealth', stealthMode: false),
        true,
      );
      expect(shouldSkipBroadcast(visibility: 'all', stealthMode: true), true);
      expect(shouldSkipBroadcast(visibility: 'all', stealthMode: false), false);
      expect(shouldSkipBroadcast(visibility: 'paired', stealthMode: false), false);
      // 有已配对设备 always 放行；无配对时仅 roll==0 放行
      expect(allowPairedBroadcast(pairedCount: 2, roll0to5: 3), true);
      expect(allowPairedBroadcast(pairedCount: 0, roll0to5: 0), true);
      expect(allowPairedBroadcast(pairedCount: 0, roll0to5: 4), false);
      // 单播回包端口：已知优先，否则默认
      expect(resolveReplyPort(knownUdpPort: 9999, defaultPort: 8888), 9999);
      expect(resolveReplyPort(knownUdpPort: null, defaultPort: 8888), 8888);
    });
  });

  group('E1 本机 IP 优选（local_ip_picker）', () {
    test('wifi 私有优先 / 192.168 优先 / 首个回退 / 无有效 null', () {
      expect(
        pickLocalIp(wifiIp: '192.168.1.5', v4Ips: const ['10.0.0.2']),
        '192.168.1.5',
      );
      // wifi 非私有则忽略，走列表优选
      expect(
        pickLocalIp(wifiIp: '8.8.8.8', v4Ips: const ['10.0.0.2', '192.168.1.9']),
        '192.168.1.9',
      );
      expect(pickLocalIp(wifiIp: null, v4Ips: const ['10.0.0.2']), '10.0.0.2');
      expect(pickLocalIp(wifiIp: '0.0.0.0', v4Ips: const []), null);
      expect(pickLocalIp(wifiIp: null, v4Ips: const []), null);
    });
  });

  group('E1 解压命名（extract_naming）', () {
    test('去 zip 后缀 + 序号命名', () {
      expect(extractFolderBase('docs.ZIP'), 'docs');
      expect(extractFolderBase('docs.zip'), 'docs');
      expect(extractFolderBase('raw'), 'raw_extracted');
      expect(uniqueFolderName(base: 'docs', existing: const {}), 'docs');
      expect(
        uniqueFolderName(base: 'docs', existing: const {'docs'}),
        'docs (1)',
      );
      expect(
        uniqueFolderName(
          base: 'docs',
          existing: const {'docs', 'docs (1)', 'docs (2)'},
        ),
        'docs (3)',
      );
    });
  });

  group('新库 logging 入口（log.dart）', () {
    test('initLogging 重复调用安全 + moduleLog 同名同实例', () {
      initLogging();
      initLogging();
      expect(identical(moduleLog('x'), moduleLog('x')), true);
    });
  });

  group('E1 历史分页（history_paging）', () {
    test('无更多/整页/尾页 clamp', () {
      final older = List.generate(250, (i) => 'm$i');
      // 已加载 100，再取一页 100：from=50，page 为 m50..m149
      var r = olderHistoryPage(older: older, loadedCount: 100, pageSize: 100);
      expect(r.from, 50);
      expect(r.page.length, 100);
      expect(r.page.first, 'm50');
      expect(historyHasMore(r.from), true);
      // 尾页：已加载 200，from=0，page 为前 50
      r = olderHistoryPage(older: older, loadedCount: 200, pageSize: 100);
      expect(r.from, 0);
      expect(r.page.length, 50);
      expect(historyHasMore(r.from), false);
      // 无更多
      r = olderHistoryPage(older: older, loadedCount: 250, pageSize: 100);
      expect(r.page, isEmpty);
    });
  });

  group('E1 文本插入（text_edit）', () {
    test('折叠插入/选区替换/无效回退', () {
      var r = applyTextInsert(
        current: 'hello',
        baseOffset: 2,
        extentOffset: 2,
        valid: true,
        insert: 'X',
      );
      expect(r.text, 'heXllo');
      expect(r.caret, 3);
      r = applyTextInsert(
        current: 'hello',
        baseOffset: 1,
        extentOffset: 4,
        valid: true,
        insert: 'X',
      );
      expect(r.text, 'hXo');
      expect(r.caret, 2);
      r = applyTextInsert(
        current: 'hello',
        baseOffset: 0,
        extentOffset: 0,
        valid: false,
        insert: '😀',
      );
      expect(r.text, '😀');
      expect(r.caret, 2);
      // 越界 clamp 不抛
      r = applyTextInsert(
        current: 'ab',
        baseOffset: 99,
        extentOffset: 99,
        valid: true,
        insert: 'Z',
      );
      expect(r.text, 'abZ');
    });
  });

  group('E1 待发送归类（send_path_classify）', () {
    test('目录只取首个/文件过滤/空内容判定', () {
      var c = classifySendPaths(
        paths: const ['/a/b', '/f1', '/f2'],
        kinds: const ['dir', 'file', 'file'],
      );
      expect(c.files, ['/f1', '/f2']);
      expect(c.folderPath, '/a/b');
      expect(hasSendContent(c), true);
      c = classifySendPaths(
        paths: const ['/a', '/b'],
        kinds: const ['dir', 'dir'],
      );
      expect(c.files, isEmpty);
      expect(c.folderPath, '/a');
      c = classifySendPaths(
        paths: const ['/f1', ''],
        kinds: const ['file', 'file'],
        exists: (p) => p == '/f1',
      );
      expect(c.files, ['/f1']);
      c = classifySendPaths(paths: const [], kinds: const []);
      expect(hasSendContent(c), false);
    });
  });

  group('E1 重发查找（resend_lookup）', () {
    ChatMessage fileMsg(
      String id, {
      String? transferId,
      String fileName = 'a.txt',
      TransferState state = TransferState.failed,
      bool isMe = true,
      String? filePath = '/tmp/a.txt',
    }) => ChatMessage(
      id: id,
      senderId: isMe ? 'me' : 'peer',
      content: fileName,
      type: MessageType.file,
      timestamp: DateTime.now(),
      isMe: isMe,
      fileName: fileName,
      filePath: filePath,
      transferState: state,
      transferId: transferId,
    );

    test('transferId 精确优先/旧端文件名与zip回退/无命中', () {
      final data = [
        fileMsg('m1', transferId: 't1', fileName: 'a.txt'),
        fileMsg('m2', transferId: 't2', fileName: 'b.txt'),
        fileMsg(
          'm3',
          fileName: 'c.txt',
          state: TransferState.completed,
        ),
        fileMsg('m4', fileName: 'd.txt', isMe: false),
      ];
      expect(
        findResendTargetIndex(chatData: data, transferId: 't2', fileName: 'x'),
        1,
      );
      // 旧端无 transferId：文件名回退命中 m1
      expect(
        findResendTargetIndex(chatData: data, transferId: null, fileName: 'a.txt'),
        0,
      );
      // zip 名回退
      final zipped = [fileMsg('z1', fileName: 'docs')];
      expect(
        findResendTargetIndex(
          chatData: zipped,
          transferId: null,
          fileName: 'docs.zip',
        ),
        0,
      );
      expect(
        findResendTargetIndex(
          chatData: data,
          transferId: 'nope',
          fileName: 'nope.txt',
        ),
        -1,
      );
    });
  });

  group('E1 文字入站（text_inbound）', () {
    test('解密优先回退content/空串 + ID生成 + 去重/迁移门控', () {
      expect(
        resolveInboundTextContent(
          decrypted: 'hi',
          payload: const {'content': 'raw'},
        ),
        'hi',
      );
      expect(
        resolveInboundTextContent(
          decrypted: null,
          payload: const {'content': 'raw'},
        ),
        'raw',
      );
      expect(
        resolveInboundTextContent(decrypted: null, payload: const {}),
        '',
      );
      expect(
        inboundTextMessageId(msgId: 'abc', nowMs: 1),
        'recv_abc',
      );
      expect(
        inboundTextMessageId(msgId: null, nowMs: 123),
        'recv_text_123',
      );
      expect(
        isInboundTextDuplicate(cachedIds: const ['recv_a'], msgId: 'a'),
        true,
      );
      expect(
        isInboundTextDuplicate(cachedIds: const ['recv_b'], msgId: 'a'),
        false,
      );
      expect(
        shouldMigrateLegacyCache(peerKey: 'dev', senderIp: '1.1.1.1'),
        true,
      );
      expect(
        shouldMigrateLegacyCache(peerKey: '1.1.1.1', senderIp: '1.1.1.1'),
        false,
      );
      expect(
        TransferTexts.needsAudioMetaFill(durationMs: 0, waveformData: 'x'),
        true,
      );
      expect(
        TransferTexts.resolveAudioWaveform(existing: '', fallback: 'f'),
        'f',
      );
      expect(
        TransferTexts.shouldFillMetaAfterComplete(
          state: TransferState.completed,
          type: MessageType.image,
          want: MessageType.image,
        ),
        true,
      );
      expect(
        TransferTexts.shouldFillMetaAfterComplete(
          state: TransferState.transferring,
          type: MessageType.image,
          want: MessageType.image,
        ),
        false,
      );
    });
  });

  group('E1 pending去重（pending_dedup）', () {
    ChatMessage inbound(
      String id, {
      String? transferId,
      String fileName = 'a.txt',
      TransferState state = TransferState.pending,
      bool isMe = false,
    }) => ChatMessage(
      id: id,
      senderId: isMe ? 'me' : 'peer',
      content: fileName,
      type: MessageType.file,
      timestamp: DateTime.now(),
      isMe: isMe,
      fileName: fileName,
      transferState: state,
      transferId: transferId,
    );

    test('仅收到的pending/failed参与 + transferId精确', () {
      final data = [
        inbound('m1', transferId: 't1'),
        inbound('m2', fileName: 'b.txt', state: TransferState.completed),
        inbound('m3', fileName: 'c.txt', isMe: true),
      ];
      expect(
        hasPendingDuplicate(chatData: data, transferId: 't1', fileName: 'x'),
        true,
      );
      expect(
        hasPendingDuplicate(
          chatData: data,
          transferId: null,
          fileName: 'b.txt',
        ),
        false,
      );
      expect(
        hasPendingDuplicate(
          chatData: data,
          transferId: null,
          fileName: 'c.txt',
        ),
        false,
      );
    });
  });

  group('E1 在线门控（online_check）', () {
    test('blocked优先/已知离线/心跳新鲜/ping回退', () {
      const fresh = Duration(seconds: 5);
      expect(
        decideOnlineGate(
          blocked: true,
          knownOnline: true,
          heartbeatAge: Duration.zero,
          freshWindow: fresh,
        ),
        OnlineGate.blocked,
      );
      expect(
        decideOnlineGate(
          blocked: false,
          knownOnline: false,
          heartbeatAge: null,
          freshWindow: fresh,
        ),
        OnlineGate.offlineKnown,
      );
      expect(
        decideOnlineGate(
          blocked: false,
          knownOnline: true,
          heartbeatAge: const Duration(seconds: 1),
          freshWindow: fresh,
        ),
        OnlineGate.freshOk,
      );
      expect(
        decideOnlineGate(
          blocked: false,
          knownOnline: true,
          heartbeatAge: const Duration(seconds: 30),
          freshWindow: fresh,
        ),
        OnlineGate.needPing,
      );
      expect(
        decideOnlineGate(
          blocked: false,
          knownOnline: true,
          heartbeatAge: null,
          freshWindow: fresh,
        ),
        OnlineGate.needPing,
      );
      expect(mapPingResult(true), true);
      expect(mapPingResult(false), false);
    });
  });

  group('E1 文件图标（file_icon）', () {
    test('folder优先/扩展名分类/未知回退', () {
      expect(fileIconName('x', isFolder: true), 'folder');
      expect(fileIconName('a.PDF'), 'pdf');
      expect(fileIconName('a.docx'), 'doc');
      expect(fileIconName('a.xlsx'), 'sheet');
      expect(fileIconName('a.pptx'), 'slide');
      expect(fileIconName('a.heic'), 'image');
      expect(fileIconName('a.mp4'), 'video');
      expect(fileIconName('a.flac'), 'audio');
      expect(fileIconName('a.7z'), 'archive');
      expect(fileIconName('a.apk'), 'apk');
      expect(fileIconName('a.txt'), 'text');
      expect(fileIconName('noext'), 'file');
      expect(fileIconName('a.unknownext'), 'file');
    });
  });

  group('E1/U2 分享归类（share_classify）', () {
    test('url跳过/text去空/文件透传', () {
      expect(
        classifyShareItem(type: 'url', path: 'http://x'),
        (kind: 'skip', text: null, path: null),
      );
      expect(
        classifyShareItem(type: 'text', path: '  hi  '),
        (kind: 'text', text: 'hi', path: null),
      );
      expect(
        classifyShareItem(type: 'text', path: '   '),
        (kind: 'skip', text: null, path: null),
      );
      expect(
        classifyShareItem(type: 'image', path: '/tmp/a.png'),
        (kind: 'file', text: null, path: '/tmp/a.png'),
      );
      expect(
        classifyShareItem(type: 'video', path: ''),
        (kind: 'skip', text: null, path: null),
      );
    });
  });

  group('E1 消息动作（message_actions）', () {
    test('文件有路径两动作/无路径空/文本复制', () {
      expect(fileActionLabels('/tmp/a.txt'), ['文件位置', '分享']);
      expect(fileActionLabels(''), isEmpty);
      expect(fileActionLabels(null), isEmpty);
      expect(copyActionLabels(), ['复制']);
    });
  });

  group('E1 状态映射/ACK/取消（transfer_state_map/ack/cancel）', () {
    test('映射/终态/活动/气泡快照', () {
      expect(isTerminalMsgState(TransferState.completed), true);
      expect(isTerminalMsgState(TransferState.transferring), false);
      expect(shouldGuardTerminal(TransferState.failed), true);
      expect(isActiveMsgState(TransferState.sending), true);
      expect(isActiveMsgState(TransferState.completed), false);
      expect(isCancelActiveState(TransferState.pending), true);
      expect(isCancelActiveState(TransferState.sending), false);
      expect(isResumableMsgState(TransferState.failed), true);
      expect(isResumableMsgState(TransferState.transferring), false);
      final f = bubbleFlagsOf(TransferState.transferring);
      expect(f.isTransferring, true);
      expect(f.isFailed, false);
      expect(canShowFileActions(TransferState.completed, '/a'), true);
      expect(canShowFileActions(TransferState.completed, null), false);
      expect(canShowCopyAction(isFile: false, content: 'x'), true);
      expect(canShowCopyAction(isFile: true, content: 'x'), false);
      expect(
        needsPostCompleteExtract(
          state: TransferState.completed,
          isMe: false,
          isFolder: true,
          filePath: '/a',
        ),
        true,
      );
      expect(isRejectTarget(isMe: true, state: TransferState.transferring),
          true);
      expect(
        rejectFileNameMatches(messageFileName: 'a', fileName: 'a.zip'),
        true,
      );
    });

    test('ACK三前缀/拉黑仅sending/自愈', () {
      expect(ackIndexMatches(messageId: 'x', ackMsgId: 'x'), true);
      expect(ackIndexMatches(messageId: 'send_x', ackMsgId: 'x'), true);
      expect(ackIndexMatches(messageId: 'text_x', ackMsgId: 'x'), true);
      expect(ackIndexMatches(messageId: 'y', ackMsgId: 'x'), false);
      expect(shouldMarkBlockedFailed(TransferState.sending), true);
      expect(shouldMarkBlockedFailed(TransferState.completed), false);
      expect(shouldMarkAckCompleted(TransferState.failed), true);
      expect(shouldMarkAckCompleted(TransferState.completed), false);
      expect(findAckIndex([(id: 'send_x'), (id: 'y')], (m) => m.id, 'x'), 0);
      expect(findAckIndex([(id: 'y')], (m) => m.id, 'x'), -1);
      expect(findCancelIndex([1, 2, 3], (m) => m == 2), 1);
      expect(
        hasActiveMessage(
          [TransferState.sending],
          (s) => s,
          isActiveMsgState,
        ),
        true,
      );
      expect(
        hasActiveMessage(
          [TransferState.completed],
          (s) => s,
          isActiveMsgState,
        ),
        false,
      );
      expect(progressBarValue(0), null);
      expect(progressBarValue(0.5), 0.5);
      expect(taskProgressOrZero(null), 0.0);
      expect(taskProgressOrZero(0.3), 0.3);
    });

    test('取消文案语音恒定/收发区分', () {
      expect(
        localCancelContent(isAudio: true, isMe: true, fileName: 'a'),
        '语音消息',
      );
      expect(
        localCancelContent(isAudio: false, isMe: true, fileName: 'a'),
        '📤 已取消发送: a',
      );
      expect(
        localCancelContent(isAudio: false, isMe: false, fileName: 'a'),
        '📥 已取消接收: a',
      );
      expect(
        peerCancelContent(isAudio: false, isMe: true, fileName: 'a'),
        '📤 对方已取消: a',
      );
      expect(
        peerCancelContent(isAudio: false, isMe: false, fileName: 'a'),
        '📥 对方已取消: a',
      );
    });

    test('拉黑批量/拒绝查找/入站重发查找', () {
      ChatMessage m(
        String id, {
        bool isMe = true,
        TransferState state = TransferState.sending,
        MessageType type = MessageType.text,
        String? fileName,
        String? filePath,
      }) =>
          ChatMessage(
            id: id,
            senderId: isMe ? 'me' : 'peer',
            content: 'c',
            type: type,
            timestamp: DateTime.now(),
            isMe: isMe,
            fileName: fileName,
            filePath: filePath,
            transferState: state,
          );
      final r = applyBlockSyncFailed([
        m('a', state: TransferState.sending),
        m('b', state: TransferState.completed),
        m('c', isMe: false, state: TransferState.sending),
      ]);
      expect(r.changed, true);
      expect(r.ids, {'a'});
      expect(r.messages.first.transferState, TransferState.failed);
      expect(
        findRejectTargetIndex(
          chatData: [
            m('x',
                state: TransferState.transferring,
                type: MessageType.file,
                fileName: 'a.txt'),
          ],
          fileName: 'a.txt',
        ),
        0,
      );
      expect(
        findRejectTargetIndex(chatData: [m('y')], fileName: 'a.txt'),
        -1,
      );
      expect(
        findInboundResendIndex(
          chatData: [
            m('z',
                isMe: false,
                state: TransferState.failed,
                type: MessageType.file,
                fileName: 'b.txt'),
          ],
          transferId: null,
          fileName: 'b.txt',
        ),
        0,
      );
    });
  });

  group('E1 对端身份（peer_identity）', () {
    test('回退/指纹/忽略门控', () {
      expect(resolveTargetIp(peerIp: '1.1.1.1', id: '2.2.2.2'), '1.1.1.1');
      expect(resolveTargetIp(peerIp: '', id: '2.2.2.2'), '2.2.2.2');
      expect(resolveTargetIp(peerIp: '0.0.0.0', id: '2.2.2.2'), '2.2.2.2');
      expect(resolvePeerFingerprint('a' * 64), 'a' * 64);
      expect(resolvePeerFingerprint('1.1.1.1'), null);
      expect(isDeviceIdValid('1.1.1.1'), true);
      expect(isDeviceIdValid('0.0.0.0'), false);
      expect(
        shouldIgnoreIncoming(
          deviceId: '1.1.1.1',
          peerIp: '1.1.1.1',
          targetIp: '1.1.1.1',
          senderIp: '9.9.9.9',
        ),
        true,
      );
      expect(
        shouldIgnoreIncoming(
          deviceId: '0.0.0.0',
          peerIp: '',
          targetIp: '',
          senderIp: '9.9.9.9',
        ),
        false,
      );
    });
  });

  group('E1 重传策略（text_retry_policy）', () {
    test('退避/去重/放弃/节流', () {
      expect(ackTimeoutFor(0, baseMs: 800).inMilliseconds, 800);
      expect(ackTimeoutFor(2, baseMs: 800).inMilliseconds, 3200);
      expect(
        shouldSkipDuplicateSend(retry: 0, alreadyPending: true),
        true,
      );
      expect(
        shouldSkipDuplicateSend(retry: 1, alreadyPending: true),
        false,
      );
      expect(
        shouldAbortTextRetry(blockedLocal: false, blockedByPeer: true),
        true,
      );
      expect(nextTextRetry(1), 2);
      expect(shouldGiveUpText(4, maxRetries: 3), true);
      expect(shouldGiveUpText(3, maxRetries: 3), false);
      expect(
        shouldThrottleProgress(lastTickMs: 100, nowMs: 150),
        true,
      );
      expect(
        shouldThrottleProgress(lastTickMs: 0, nowMs: 200),
        false,
      );
      final recent = <String, DateTime>{};
      final now = DateTime.now();
      expect(
        isRecvDuplicate(
          recent: recent,
          msgId: 'a',
          now: now,
          ttl: const Duration(seconds: 5),
          existsInChat: false,
        ),
        false,
      );
      expect(
        isRecvDuplicate(
          recent: recent,
          msgId: 'a',
          now: now,
          ttl: const Duration(seconds: 5),
          existsInChat: false,
        ),
        true,
      );
    });
  });

  group('E1 气泡元信息（bubble_meta）', () {
    test('长按/取消/缺失/路径/百分比/文案', () {
      expect(
        canLongPressBubble(
          isTransferring: false,
          isSending: false,
          isFile: true,
          content: '',
        ),
        true,
      );
      expect(
        canLongPressBubble(
          isTransferring: true,
          isSending: false,
          isFile: true,
          content: 'x',
        ),
        false,
      );
      expect(shouldShowCancel(isMe: false, autoReceive: true), false);
      expect(shouldShowCancel(isMe: true, autoReceive: true), true);
      expect(
        isImageMissing(
          isCompleted: true,
          fileExists: false,
          originalExists: false,
        ),
        true,
      );
      expect(
        resolveDisplayImagePath(thumb: null, image: '/b', file: '/c'),
        '/b',
      );
      expect(resolveOriginalImagePath(image: null, file: '/c'), '/c');
      expect(formatProgressPercent(0.126), '13%');
      expect(avatarLetter(''), '机');
      expect(avatarLetter('abc'), 'a');
      expect(folderDisplayName(fileName: 'd.zip', isFolder: true), 'd');
      expect(folderDisplayName(fileName: null, isFolder: false), '未知文件');
      expect(retryLabel(isText: true), '点击重发');
      expect(isBlankText('   '), true);
      expect(
        extractOriginalTextForResend('⚠️ 发送失败: hi\n（点击重发）'),
        'hi',
      );
    });
  });

  group('E1 发送命名（send_naming）', () {
    test('ID/标签/路径/门控', () {
      expect(
        newSendMsgId(isRetry: true, existingId: 'old', nowMs: 1),
        'old',
      );
      expect(newSendMsgId(isRetry: false, existingId: null, nowMs: 1),
          'send_1');
      expect(newSendErrId(1), 'err_1');
      expect(newTextMsgId(7), '7');
      expect(buildAudioFileName(7), '语音消息_7.m4a');
      expect(buildAudioMsgId(7), 'audio_7');
      expect(stripZipSuffixForDisplay('a.ZIP'), 'a');
      expect(sendErrLabel(isFolder: true), '📁');
      expect(legacyAcceptKey('d', 'f'), 'd_f');
      expect(
        needsPinRetry(rejected: true, reason: 'pinWrong', attempt: 0),
        true,
      );
      expect(
        needsPinRetry(rejected: true, reason: 'pinWrong', attempt: 1),
        false,
      );
      expect(buildRecvMsgId('t'), 'recv_t');
      expect(resolveRecvFilePath(savedPath: null, filePath: '/a'), '/a');
      expect(
        resolveRecvImagePath(isImage: false, savedPath: '/a', filePath: '/b'),
        null,
      );
      final z = buildFolderZipPath(
        folderPath: '/x/docs',
        tempDirPath: '/tmp',
        stampUs: 5,
        basename: 'docs',
      );
      expect(z.zipFileName, 'docs.zip');
      expect(z.zipPath, '/tmp/5_docs.zip');
      expect(
        buildThumbName(fileName: 'a', nowMs: 1),
        'thumb_${'a'.hashCode.abs()}_1.jpg',
      );
      expect(buildThumbPath(thumbDir: '/t', thumbName: 'n'), '/t/n');
    });
  });

  group('E1 发送等待文案（send_waiting_texts）', () {
    test('等待/PIN/异常/录音/pending', () {
      expect(
        buildSendWaitingContent(errLabel: '📤', displayName: 'a'),
        '📤 等待对方同意: a',
      );
      expect(
        buildPinRequiredFailure(errLabel: '📤', displayName: 'a'),
        '📤 对方已拒绝: a（需 PIN）',
      );
      expect(
        buildSendExceptionContent(
          errLabel: '📤',
          displayName: 'a',
          truncatedError: 'boom',
        ),
        '📤 发送失败: a\nboom',
      );
      expect(audioHandshakeFailedContent(rejected: true), '语音消息（对方已拒绝）');
      expect(isTooShortRecord(durationMs: 100), true);
      expect(isTooShortRecord(durationMs: 900), false);
      expect(
        isInRecordCancelZone(globalY: 10, screenHeight: 100),
        true,
      );
      expect(pendingLabel(isFolder: true), '📁');
      expect(
        buildPendingContent(label: '📥', fileName: 'a', batchSuffix: ''),
        '📥 等待接收: a',
      );
      expect(filePickFailedText('boom'), '文件选择失败: boom');
      expect(folderMissingText(), '文件夹不存在');
      expect(folderEmptyText(), '所选文件夹为空');
      expect(folderPackFailedText(), '文件夹打包失败');
      expect(extractTooLargeText('d.zip'), '文件夹过大，无法自动解压（d.zip）');
      expect(extractAbortedText('d.zip'), '文件夹过大，已停止解压（d.zip）');
      expect(blockedByPeerText(), '对方已拉黑，无法发送');
      expect(peerOfflineText(), '对方未在线，无法发送');
      expect(recordTooShortText(), '录音时间太短');
      expect(copyDoneText(), '已复制');
      expect(pinDialogTitle(), '对方要求输入 PIN');
      expect(pinWrongHint(), 'PIN 错误，请重新输入对方的接收 PIN');
    });
  });

  group('E1 图片/解压（media_layout）', () {
    test('尺寸/守卫/序号', () {
      final s = calcImageDisplaySize(imageSize: null, screenWidth: 100);
      expect(s.width, 100 * 0.55 * 0.75);
      expect(isSuspiciousZipEntry('a/../b'), true);
      expect(isSuspiciousZipEntry('a/b'), false);
      expect(exceedsExtractLimit(total: 5, add: 6, limit: 10), true);
      expect(isPathInside(targetAbs: '/a', childAbs: '/a/b'), true);
      expect(nextIndexedFolderName('d', 1), 'd (1)');
    });
  });

  group('E1 设备查找（device_lookup）', () {
    test('广播/配对/可见性/端口', () {
      expect(isOversizeBroadcast('x'), false);
      expect(onlineLabelForCmd('i_see_you'), '已通过单播握手成功');
      expect(
        shouldDirectReply(cmd: 'iamalive', type: 'mobile', isMobile: false),
        true,
      );
      expect(normalizeUdpPort({'udpPort': '9'}, 1, 2), 9);
      expect(normalizeTcpPort({}, 2), 2);
      expect(isSelfMdns(ip: 'a', localIp: 'a', localList: const []), true);
      expect(mdnsDeviceKey(deviceId: '', ip: 'a'), 'a');
      expect(
        shouldShowPairing(
          isFingerprintKey: true,
          paired: false,
          blocked: false,
          inProgress: false,
        ),
        true,
      );
      expect(visibilityToast('stealth'), '已切换：隐身模式');
      expect(stealthForVisibility('stealth'), true);
      expect(udpFallbackText(1, 2), 'UDP 端口 1 被占用，已改用 2');
      expect(tcpFallbackText(1, 2), 'TCP 1 被占用，已改用 2');
      expect(tcpUpdatedText(3), 'TCP 端口已更新为 3');
      expect(deviceNoResponseText(9), '设备无响应，请检查 IP 与 UDP 端口 9');
      expect(joinFallback(null, 'b'), 'b');
    });
  });

  group('E1 到达文案（arrival_texts）', () {
    test('标签/内容/pending/手动', () {
      expect(arrivalLabel(true), '📁');
      expect(arrivalMsgId('t'), 'recv_t');
      expect(
        arrivalContent(
          isVoice: true,
          label: '📥',
          fileName: 'a',
          batchSuffix: '',
        ),
        '语音消息',
      );
      expect(
        arrivalContent(
          isVoice: false,
          label: '📥',
          fileName: 'a',
          batchSuffix: '',
        ),
        '📥 接收中: a (0%)',
      );
      expect(
        pendingContent(emoji: '📥', fileName: 'a', batchSuffix: ''),
        '📥 等待接收: a',
      );
      expect(notifyToastLabel(true), '📁文件夹');
      expect(manualName(true), '手动设备');
      expect(manualLastMsg(false), '手动添加：未响应，请检查端口');
    });
  });

  group('E1 气泡布局/文件命令/黑名单/选择器（action_bubble/file_location/blocked/pick）',
      () {
    test('宽度估算/clamp/命令分支/集合合并', () {
      expect(actionBubbleWidth(labels: const ['a'], screenWidth: 400), 76.0);
      final layout = computeActionBubbleLayout(
        labels: const ['复制'],
        targetLeft: 0,
        targetTop: 100,
        targetRight: 100,
        targetBottom: 120,
        targetCenterX: 50,
        screenWidth: 400,
        screenHeight: 800,
        safeTop: 0,
        safeBottom: 0,
      );
      expect(layout.popupWidth, 76.0);
      expect(layout.arrowOnTop, layout.showBelow);
      final win = buildOpenLocationCommand(
        isWindows: true,
        isMacOS: false,
        isLinux: false,
        isDirectory: false,
        filePath: '/a/b',
        dirPath: '/a',
      );
      expect(win?.exe, 'explorer');
      expect(
        buildOpenLocationCommand(
          isWindows: false,
          isMacOS: false,
          isLinux: false,
          isDirectory: false,
          filePath: '/a',
          dirPath: '/a',
        ),
        null,
      );
      expect(parseBlockedList('["a","b"]'), ['a', 'b']);
      expect(isDeviceBlocked(['a'], 'a'), true);
      expect(
        mergeBlockedList(current: ['a'], deviceId: 'b', blocked: true),
        ['a', 'b'],
      );
      expect(
        mergeBlockedList(current: ['a'], deviceId: 'a', blocked: false),
        isEmpty,
      );
      expect(galleryExtensions(), contains('heic'));
      expect(isSinglePick(1), true);
      expect(isSinglePick(2), false);
      expect(classifyPickCount(0), 'empty');
    });
  });

  group('E1 设备合并/tile/PIN（device_merge/device_tile_meta/pin_texts）', () {
    test('无变化/类型/过滤/门控/文案', () {
      expect(
        isDeviceUnchanged(
          name: 'n',
          type: 't',
          onlineStatus: 'online',
          currentIp: 'ip',
          udpPort: 1,
          tcpPort: 2,
          lastMsg: 'm',
          curName: 'n',
          curType: 't',
          curOnlineStatus: 'online',
          curIp: 'ip',
          curUdpPort: 1,
          curTcpPort: 2,
          curLastMsg: 'm',
        ),
        true,
      );
      expect(dirKindForEntity(isDirectory: true), 'dir');
      expect(isDefaultStorageLabel('默认文件夹'), true);
      expect(isMobileType('mobile'), true);
      expect(filterOnline(['1', '2'], {'1'}, (e) => e), ['1']);
      expect(filterOffline(['1', '2'], {'1'}, (e) => e), ['2']);
      expect(sortOnlineFirst(['2', '1'], {'1'}, (e) => e), ['1', '2']);
      expect(
        dropEnabled(isDesktop: true, loadingCache: false, hasOpenChat: false),
        true,
      );
      expect(isInvalidDeviceId('0.0.0.0'), true);
      expect(shouldKeepWaitingOnline(tried: 14), true);
      expect(shouldKeepWaitingOnline(tried: 15), false);
      expect(pinSavedText(''), '接收 PIN 已关闭');
      expect(pinSavedText('1234'), '接收 PIN 已启用');
      expect(peerFingerprintOrNull('AB', true), 'ab');
      expect(peerFingerprintOrNull('AB', false), null);
    });
  });

  group('E3 并发写串行（synchronized 新库）', () {
    test('同设备并发 append 不丢消息', () async {
      final dir = await Directory.systemTemp.createTemp('wlt_lock');
      try {
        final cache = MessageCacheService.forTest(dir.path);
        ChatMessage msg(String id) => ChatMessage(
          id: id,
          senderId: '1.1.1.1',
          content: 'hi',
          type: MessageType.text,
          timestamp: DateTime.now(),
          isMe: false,
        );
        await Future.wait([
          for (var i = 0; i < 20; i++) cache.appendMessage('dev', msg('m$i')),
        ]);
        await cache.flushPending();
        final loaded = await cache.loadMessages('dev');
        expect(loaded.length, 20);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('audio_bubble_meta', () {
    test('宽度/时长/波形/进度/路径/切歌', () {
      expect(calcAudioBubbleWidth(durationMs: 0), 90.0);
      expect(calcAudioBubbleWidth(durationMs: 60000), 200.0);
      expect(calcAudioBubbleWidth(durationMs: 600000), 200.0);
      expect(formatAudioBubbleDuration(12000), '12"');
      expect(formatAudioBubbleDuration(65000), contains('\u2032'));
      final neutral = parseOrNeutralWaveform(null);
      expect(neutral.length, 25);
      expect(neutral.every((e) => e == 0.25), true);
      expect(tryParseWaveformBars('[1,2]'), [1.0, 2.0]);
      expect(tryParseWaveformBars('not json'), isNull);
      expect(tryParseWaveformBars(null), isNull);
      expect(playProgressOf(progressMs: 500, durationMs: 0), 0.5);
      expect(audioPlayPath(filePath: '', imagePath: ''), isNull);
      expect(audioPlayPath(filePath: '', imagePath: '/b'), '/b');
      expect(
        shouldStopForOtherPath(
          currentPlaying: 'a',
          ourPath: 'b',
          isPlaying: true,
        ),
        true,
      );
      expect(
        shouldStopForOtherPath(
          currentPlaying: 'a',
          ourPath: 'a',
          isPlaying: true,
        ),
        false,
      );
    });
  });

  group('emoji_bubble_texts', () {
    test('码点/列表/气泡文案', () {
      expect(keepEmojiCodePoint(0x1F4D0), false);
      expect(keepEmojiCodePoint(0x1F600), true);
      final list = buildEmojiList();
      expect(list.isNotEmpty, true);
      expect(
        list.every(
          (e) =>
              e.runes.isEmpty ||
              e.runes.first < 0x1F4D0 ||
              e.runes.first > 0x1F4FF,
        ),
        true,
      );
      expect(leaveConfirmTexts().title, '传输进行中');
      expect(imageFailText(isMe: true), contains('发送失败'));
      expect(extractAbortedContent('d.zip'), contains('d.zip'));
      expect(recordCancelHint(cancelling: true), contains('松开'));
      expect(recordCancelHint(cancelling: true), contains('取消'));
      expect(recordHoldHint(), contains('按住'));
      expect(recordHoldHint(), contains('说话'));
      expect(imageViewerTitle(), '图片');
    });
  });

  group('chat_list_texts', () {
    test('配对/空间/到达/拉黑/端口/IP/批量', () {
      expect(pairTrustedText('小明'), contains('小明'));
      expect(noSpaceReceiveText('a.txt'), contains('a.txt'));
      expect(
        arrivalToastText(label: '📥', deviceName: 'Pixel', fileName: 'a.txt'),
        '📥 Pixel 发来文件: a.txt',
      );
      expect(blockedByNameText('小明'), contains('拉黑'));
      expect(noOnlineDeviceShortText().isNotEmpty, true);
      expect(noOnlineDeviceLongText().isNotEmpty, true);
      expect(noOnlineDeviceShortText() != noOnlineDeviceLongText(), true);
      expect(handshakeFailText(8888), contains('8888'));
      expect(localIpText('192.168.1.2'), contains('192.168.1.2'));
      expect(batchHintText().isNotEmpty, true);
    });
  });

  group('E1 消息工厂/录音策略（message_factory/record_policy）', () {
    test('外发/入站构造与录音上限', () {
      final now = DateTime(2026, 10, 9);
      final out = buildOutgoingText(msgId: '1', text: 'hi', now: now);
      expect(out.id, '1');
      expect(out.transferState, TransferState.sending);
      expect(out.isMe, true);
      final inc = buildIncomingText(
        id: 'recv_1',
        senderId: '1.1.1.1',
        content: 'hi',
        now: now,
      );
      expect(inc.isMe, false);
      final audio = buildOutgoingAudio(
        msgId: 'a1',
        fileName: 'f.m4a',
        fileSizeText: '1KB',
        filePath: '/tmp/f.m4a',
        content: audioLabel(),
        transferId: 't1',
        durationMs: 1000,
        waveformData: null,
        now: now,
      );
      expect(audio.type, MessageType.audio);
      expect(audio.transferState, TransferState.pending);
      final file = buildOutgoingFile(
        msgId: 's1',
        content: 'wait',
        isImage: true,
        displayName: 'a.jpg',
        fileSizeText: '2KB',
        filePath: '/tmp/a.jpg',
        thumbPath: null,
        transferId: 't2',
        sessionId: null,
        isFolder: false,
        now: now,
      );
      expect(file.type, MessageType.image);
      expect(file.imagePath, '/tmp/a.jpg');
      final missing = buildSendMissingFile(
        id: 'err_1',
        content: 'gone',
        isImage: false,
        displayName: 'a.txt',
        filePath: '/tmp/a.txt',
        isFolder: false,
        now: now,
      );
      expect(missing.transferState, TransferState.failed);
      final pend = buildInboundPending(
        pendingId: 'p1',
        senderIp: '1.1.1.1',
        content: 'wait',
        isVoice: true,
        fileName: 'v.m4a',
        fileSizeText: null,
        isFolder: false,
        transferId: 't3',
        sessionId: null,
        durationMs: 0,
        waveformData: null,
        now: now,
      );
      expect(pend.type, MessageType.audio);
      expect(pend.filePath, isNull);
      final arr = buildInboundArrival(
        id: 'recv_t1',
        senderIp: '1.1.1.1',
        content: 'ing',
        type: MessageType.file,
        fileName: 'a.txt',
        fileSizeText: null,
        filePath: '/tmp/a.txt',
        imagePath: null,
        taskId: 't1',
        transferId: 't3',
        sessionId: null,
        isFolder: false,
        durationMs: 0,
        waveformData: null,
        now: now,
      );
      expect(arr.transferState, TransferState.transferring);
      expect(audioLabel(), '语音消息');
      expect(shouldAutoStopRecord(59999), false);
      expect(shouldAutoStopRecord(60000), true);
      expect(nextRecordDuration(0), kRecordTickMs);
      expect(exceedsSampleCap(kMaxWaveSamples), false);
      expect(exceedsSampleCap(kMaxWaveSamples + 1), true);
      expect(exceedsUiAmpCap(kMaxUiAmps + 1), true);
    });
  });

  group('E1 默认值/上限/小页面（chat_defaults/transfer_limits/more/pairing/settings/info）', () {
    test('占位/常量/映射/校验', () {
      expect(kUnknownIp, '未知IP');
      expect(isUnknownIp(kUnknownIp), true);
      expect(isDefaultStorageTag(kDefaultStorageLabel), true);
      expect(kHistoryPageSize, 100);
      expect(kMaxTextRetries, 3);
      expect(kThumbQuality, 70);
      expect(kImageMaxHeight, 220);
      expect(moreActionKey('文件'), 'file');
      expect(moreActionKey('未知项'), 'unknown');
      expect(
        needsNotImplementedFallback(
          key: 'photo',
          hasPhoto: false,
          hasCamera: true,
          hasFolder: true,
        ),
        true,
      );
      expect(moreNotImplementedText('照片'), contains('功能开发中'));
      expect(shortFingerprint('abc'), 'abc');
      expect(shortFingerprint('0123456789abcdefXYZ'), '0123456789abcdef');
      expect(pairingTitle(), '发现新设备');
      expect(isValidPort(80), false);
      expect(isValidPort(8888), true);
      expect(portDialogTitle(udp: true), contains('UDP'));
      expect(visibilityOptAll(), '所有人可见');
      expect(infoTitle(), '设备详情');
      expect(infoClearContent('A'), contains('A'));
    });
  });

  group('E1 时序/容量/提示/记账（transfer_limits/send_dispatch/toast/security）', () {
    test('快发/ping/toast/容量/记账', () {
      expect(kBroadcastFastMs1, 200);
      expect(kBroadcastFastMs2, 600);
      expect(kPingTimeoutSec, 2);
      expect(kToastSec, 3);
      expect(kActionBubbleSec, 3);
      expect(kPinMaxFails, 5);
      expect(kStaleCacheDays, 7);
      expect(kStaleTempZipHours, 24);
      expect(kMaxSessionCount, 200);
      expect(kMaxCacheEntries, 50);
      expect(kMaxThumbFiles, 200);
      expect(kRecvDedupTtlSec, 30);
      expect(kLaunchSendWaitSec, 15);
      expect(sendDispatchKey(type: 'unknown', isImageFlag: true), 'image');
      expect(resolveSendIsImage(type: 'image', isImageFlag: false), true);
      expect(shouldLoadOlder(pixels: 10, hasMore: true), true);
      expect(shouldKeepWaitingOnline(tried: 14), true);
      expect(shouldKeepWaitingOnline(tried: 15), false);
      expect(selfAvatarLetter(), '我');
      expect(isEndAlign(true), true);
      expect(isEndAlign(false), false);
      expect(parseSecurityConfig(null), isEmpty);
      expect(parseSecurityConfig('bad'), isEmpty);
      final cfg = parseSecurityConfig('{"a":1}');
      final next = appendSecurityEvent(
        config: cfg,
        type: 'reset_identity',
        timeIso: 't',
        fingerprint: 'fp',
      );
      expect((next['events'] as List).length, 1);
      final b = BoundedCache<String>();
      expect(b.capacity, kMaxCacheEntries);
      final s = SessionTracker();
      expect(s.capacity, kMaxSessionCount);
      final p = PinFailLimiter();
      expect(p.maxFails, kPinMaxFails);
    });
  });

  group('E1 文字队列/图片缓存（text_send_queue/image_existence_cache）', () {
    test('队列FIFO/缓存裁剪', () async {
      final q = TextSendQueue();
      expect(q.isEmpty, true);
      q.add(const QueuedText('m1', 'hi', 0));
      q.add(const QueuedText('m2', 'yo', 1));
      expect(q.length, 2);
      expect(q.needsGap, true);
      q.running = true;
      expect(q.takeNext()?.msgId, 'm1');
      expect(q.takeNext()?.msgId, 'm2');
      expect(q.takeNext(), null);
      q.clear();
      expect(q.running, false);

      final img = ImageExistenceCache(capacity: 4);
      expect(img.lookupExists('/a'), null);
      expect(img.lookupSize('/a'), null);
      img.storeExists('/a', true);
      expect(img.lookupExists('/a'), true);
      img.storeExists('/b', false);
      img.storeExists('/c', true);
      img.storeExists('/d', true);
      img.storeExists('/e', true);
      expect(img.exists.length <= 4, true);
      img.clear();
      expect(img.exists.isEmpty, true);
    });
  });

  group('E1 缓存恢复决策（chat_recovery）', () {
    test('活动追认/中断/已完成解压检查/保持', () {
      expect(
        decideRecoveryAction(
          state: TransferState.transferring,
          isMe: false,
          type: MessageType.file,
          hasPath: true,
          isFolder: false,
        ),
        RecoveryAction.recoverCompleted,
      );
      expect(
        decideRecoveryAction(
          state: TransferState.sending,
          isMe: true,
          type: MessageType.text,
          hasPath: false,
          isFolder: false,
        ),
        RecoveryAction.markInterrupted,
      );
      expect(
        decideRecoveryAction(
          state: TransferState.completed,
          isMe: false,
          type: MessageType.file,
          hasPath: true,
          isFolder: true,
        ),
        RecoveryAction.checkPostExtract,
      );
      expect(
        decideRecoveryAction(
          state: TransferState.completed,
          isMe: true,
          type: MessageType.text,
          hasPath: false,
          isFolder: false,
        ),
        RecoveryAction.keep,
      );
      expect(
        shouldRecoverCompleted(fileExists: false, dirExists: true),
        true,
      );
      expect(
        shouldRecoverCompleted(fileExists: false, dirExists: false),
        false,
      );
      expect(
        shouldCreateBeforeProgress(isTransferring: true, hasBubble: false),
        true,
      );
      expect(
        shouldCreateBeforeProgress(isTransferring: true, hasBubble: true),
        false,
      );
    });
  });

  group('E1 气泡/Tile/绘制/到达残余（bubble_meta/device_tile/action/audio/file_size/arrival）', () {
    test('颜色门控/几何/尺寸后缀', () {
      expect(audioTransferBubbleColor(isMe: true), 0xFF95EC69);
      expect(audioTransferBubbleColor(isMe: false), 0xFFFFFFFF);
      expect(chatAvatarBg(isMe: true), 0xFF009688);
      expect(chatAvatarBg(isMe: false), 0xFF607D8B);
      expect(canRetryAudioTap(isMe: true, filePath: '/a'), true);
      expect(canRetryAudioTap(isMe: true, filePath: null), false);
      expect(fileIconFg(isFailed: true), 0xFFE57373);
      expect(fileIconFg(isFailed: false), 0xFF5B9CF5);
      expect(showTileOnlineRing(isOnline: true), true);
      expect(deviceNameStyle(isOnline: true).weight, 600);
      expect(deviceNameStyle(isOnline: false).weight, 500);
      expect(tileSubtitleColor(isOnline: true), 0xFF757575);
      expect(useSolidTabIcon(currentIndex: 0, tabIndex: 0), true);
      expect(useSolidTabIcon(currentIndex: 0, tabIndex: 1), false);
      expect(bubbleRectTop(arrowOnTop: true, arrowH: 7), 7);
      expect(bubbleBodyHeight(height: 47, arrowH: 7), 40);
      expect(
        arrowTriangle(
          arrowOnTop: true,
          centerX: 10,
          arrowW: 11,
          arrowH: 7,
          height: 47,
        ).length,
        3,
      );
      expect(
        shouldRepaintBubble(
          arrowX: 1,
          arrowOnTop: true,
          oldArrowX: 1,
          oldArrowOnTop: true,
        ),
        false,
      );
      final g = waveBarLayout(
        index: 0,
        count: 2,
        amplitude: 1,
        totalWidth: 100,
        totalHeight: 40,
      );
      expect(g.width > 0, true);
      expect(playedBarCount(total: 10, progress: 0.55), 6);
      expect(isBarPlayed(index: 2, playedCount: 3), true);
      expect(clampBarStroke(10), 3.5);
      expect(formatSizeSuffix(0, (b) => '$b'), '');
      expect(formatSizeSuffix(1000, (b) => 'S'), '(S)');
      expect(formatSizeTextOrNull(0, (b) => 'S'), null);
      expect(resolveArrivalMsgType(isVoice: true, isImage: true), 'audio');
      expect(
        resolveArrivalMsgType(isVoice: false, isImage: true),
        'image',
      );
      expect(
        resolveArrivalBatchSuffix(
          isVoice: true,
          sessionId: 's',
          fileCount: 2,
          fileIndex: 0,
          suffixOf: (_, _, _) => 'X',
        ),
        '',
      );
      expect(useKeyboardIcon(isVoice: true), true);
      expect(useKeyboardForPanel(expanded: false), false);
      expect(shouldShowSendButton(text: ''), false);
      expect(shouldShowSendButton(text: 'hi'), true);
      expect(resolveRetrySendType(MessageType.image), SendActionType.image);
      expect(resolveRetrySendType(MessageType.file), SendActionType.file);
    });
  });

  group('E1残余收敛', () {
    test('待发送门控/批量/输入判空', () {
      expect(hasPendingText(null), false);
      expect(hasPendingText(''), false);
      expect(hasPendingText('hi'), true);
      expect(hasPendingFolder(''), false);
      expect(hasPendingPaths([]), false);
      expect(hasPendingPaths(['a']), true);
      expect(isSinglePathBatch(1), true);
      expect(isSinglePathBatch(2), false);
      expect(isNullOrEmptyInput(null), true);
      expect(isNullOrEmptyInput(''), true);
      expect(isNullOrEmptyInput('x'), false);
    });

    test('选择器空门控/批量元组', () {
      expect(isEmptyPick(null), true);
      expect(isEmptyPick([]), true);
      expect(isEmptyPick([1]), false);
      final tuples = buildBatchTuples(
        ['/a/b.png', '/a/c.txt'],
        (p) => p.split('/').last,
        (p) => p.endsWith('.png'),
      );
      expect(tuples.length, 2);
      expect(tuples.first.isImage, true);
      expect(tuples.last.name, 'c.txt');
    });

    test('入站msgId/blocked解析', () {
      expect(parseInboundMsgId({'msgId': 'm1'}), 'm1');
      expect(parseInboundMsgId({}), null);
      expect(parseBlockedFlag({'blocked': true}), true);
      expect(parseBlockedFlag({}), false);
    });

    test('ACK定时器取消语义', () {
      var cancelled = 0;
      final pending = <String, String>{'a': 't', 'b': 't'};
      final retries = <String, int>{'a': 1, 'b': 2};
      cancelAckTimer(pending, retries, 'a', (_) => cancelled++);
      expect(cancelled, 1);
      expect(pending.containsKey('a'), false);
      expect(retries.containsKey('a'), false);
      cancelAckTimersForIds(pending, retries, ['b', 'missing'], (_) => cancelled++);
      expect(cancelled, 2);
      expect(pending.isEmpty, true);
      expect(shouldRetryPinAttempt(attempt: 0), true);
      expect(
        shouldRetryPinAttempt(attempt: 0, max: kPinRetryAttempts),
        true,
      );
      expect(
        shouldRetryPinAttempt(attempt: kPinRetryAttempts),
        false,
      );
    });

    test('命名兜底/PIN提示/批量门控', () {
      expect(fileNameOrEmpty(null), '');
      expect(fileNameOrEmpty('a'), 'a');
      expect(isPinWrongReason('pinWrong'), true);
      expect(isPinWrongReason('pinRequired'), false);
      expect(resolvePinHint('pinWrong'), pinWrongHint());
      expect(resolvePinHint('pinRequired'), pinRequiredHint());
      expect(shouldAbortBatchSend(empty: true, online: true), true);
      expect(shouldAbortBatchSend(empty: false, online: false), true);
      expect(shouldAbortBatchSend(empty: false, online: true), false);
    });

    test('取消路由/音频判定/缩略图门控/路径回退', () {
      expect(
        resolveCancelRoute(taskId: 't', transferId: null),
        'cancel',
      );
      expect(
        resolveCancelRoute(taskId: null, transferId: 'x'),
        'abort',
      );
      expect(
        resolveCancelRoute(taskId: null, transferId: null),
        'none',
      );
      expect(isAudioMessageType('audio'), true);
      expect(isAudioMessageType('file'), false);
      expect(
        shouldLogNonExtractCompletion(
          stateName: 'completed',
          isSender: false,
        ),
        true,
      );
      expect(
        shouldLogNonExtractCompletion(stateName: 'completed', isSender: true),
        false,
      );
      expect(
        shouldApplyThumbnail(thumbPath: 'p', mounted: true, index: 0),
        true,
      );
      expect(
        shouldApplyThumbnail(thumbPath: null, mounted: true, index: 0),
        false,
      );
      expect(resolveImagePathFallback('i', 'f'), 'i');
      expect(resolveImagePathFallback(null, 'f'), 'f');
      expect(firstNonNullId(null, 'b'), 'b');
      expect(
        resolveProgressContentKind(isAudio: true, isSenderContent: true),
        'audio',
      );
      expect(
        resolveProgressContentKind(isAudio: false, isSenderContent: true),
        'send',
      );
      expect(
        resolveProgressContentKind(isAudio: false, isSenderContent: false),
        'receive',
      );
      expect(needsDurationProbe(0), true);
      expect(isInvalidDuration(-1), true);
      expect(needsDurationProbe(100), false);
    });

    test('缩略图目录/zip门控/解压路径/emoji网格/预览', () {
      expect(buildThumbnailDirPath('/d'), '/d/thumbnails');
      expect(shouldCreateThumbnailDir(exists: false), true);
      expect(shouldCreateThumbnailDir(exists: true), false);
      expect(isZipTooLarge(length: 11, maxBytes: 10), true);
      expect(isZipTooLarge(length: 10, maxBytes: 10), false);
      expect(joinExtractOutputPath('/t', 'a/b'), '/t/a/b');
      expect(joinExtractPath('/t', 'a'), '/t/a');
      final gp = emojiGridParams();
      expect(gp.maxExtent, 45.0);
      expect(gp.fontSize, 26.0);
      expect(shouldShowViewer(exists: true), true);
      expect(viewerScaleRange().min, 0.5);
    });

    test('录音UI/设备合并/在线过滤/滚动视口', () {
      expect(recordIconIsDelete(cancelling: true), true);
      expect(recordIconIsDelete(cancelling: false), false);
      expect(
        recordMaskCircleColor(cancelling: true),
        maskCircleColor(cancelling: true),
      );
      expect(recordButtonFg(cancelling: true) != 0, true);
      final devs = [
        (id: 'a', ip: '1.1.1.1'),
        (id: 'b', ip: '2.2.2.2'),
      ];
      expect(
        findDeviceMergeIndex(devs, (d) => d.id, (d) => d.ip, 'b', '9.9.9.9'),
        1,
      );
      expect(
        findDeviceMergeIndex(devs, (d) => d.id, (d) => d.ip, 'x', '1.1.1.1'),
        0,
      );
      expect(dropKindForItem(true), 'dir');
      expect(dropKindForItem(false), 'file');
      expect(
        filterOnlineDevices(devs, {'a'}, (d) => d.id).length,
        1,
      );
      expect(scrollBaseExtent(hasClients: false, maxExtent: 9), 0.0);
      expect(scrollBaseExtent(hasClients: true, maxExtent: 9), 9.0);
      expect(keepViewportOffset(offset: 3, grew: 4), 7.0);
      expect(clampBubbleTop(top: 5, safeTop: 0, screenH: 10, totalH: 4, safeBottom: 0), 5.0);
      expect(shouldShowActionDivider(0), false);
      expect(shouldShowActionDivider(1), true);
      expect(
        isInvalidRenderBox(isNull: true, hasSize: false),
        true,
      );
      final cache = ImageExistenceCache();
      expect(cache.lookupOrProbeExists(null, (_) => true), false);
      expect(cache.lookupOrProbeExists('/x', (_) => true), true);
      expect(cache.lookupOrProbeExists('/x', (_) => false), true);
    });

    test('F批残余收敛', () {
      expect(bufferedTaskLog('a'), contains('a'));
      expect(bufferedMsgLog('textMessage'), contains('textMessage'));
      expect(recoveredLog('f'), contains('f'));
      expect(bufferedEventsLog(3), contains('3'));
      expect(ignoreMsgLog('s', 'i', 't'), contains('s'));
      expect(invalidIdLog('x'), contains('x'));
      expect(batchSendLog('s', 2), contains('2'));
      expect(
        isRecoveryFixAction(RecoveryAction.recoverCompleted),
        true,
      );
      expect(isRecoveryFixAction(RecoveryAction.keep), false);
      expect(hasFilePath('p'), true);
      expect(hasFilePath(null), false);
      expect(isRetrySend('m'), true);
      expect(isRetrySend(null), false);
      expect(isTextCmd('textMessage'), true);
      expect(isTextCmd('fileNotify'), false);
      expect(shouldDropDuplicate('a', true), true);
      expect(shouldDropDuplicate(null, true), false);
      expect(hasFallbackHint('h'), true);
      expect(hasFallbackHint(null), false);
      expect(requireNonNullHint('h'), 'h');
      expect(parseBlockedPayload({'blocked': true}), true);
      expect(parseMsgId({'msgId': 'm'}), 'm');
      expect(totalCount([1, 2]), 2);
      expect(snapshotCount([]), 0);
      expect(hasPendingWrite('f'), true);
      expect(hasPendingWrite(null), false);
      expect(resolveSession(null, 's'), 's');
      expect(resolveSession('a', 's'), 'a');
      expect(hasSessionDecision('s'), true);
      expect(hasSessionDecision(''), false);
      expect(hasSessionDecision(null), false);
      expect(hasTransferTimerKey('k'), true);
      expect(hasTransferTimerKey(''), false);
      expect(hasQueuedText(true), true);
      expect(noOlderHistory(older: 5, loaded: 5), true);
      expect(noOlderHistory(older: 9, loaded: 5), false);
      expect(needsCacheMigrate('a', 'b'), true);
      expect(needsCacheMigrate('a', 'a'), false);
      expect(isDialogAccepted(true), true);
      expect(isDialogAccepted(false), false);
      expect(resolveSessCount(2, {'fileCount': 3}), 2);
      expect(resolveSessCount(null, {'fileCount': 3}), 3);
      expect(resolveDurationMs({'durationMs': 5}), 5);
      expect(resolveDurationMs(null), 0);
      expect(resolveWaveform({'waveformData': 'w'}), 'w');
      expect(resolveWaveform(null), null);
      expect(
        shouldSkipLaunchSend(consumed: true, empty: false),
        true,
      );
      expect(
        shouldSkipLaunchSend(consumed: false, empty: true),
        true,
      );
      expect(
        shouldSkipLaunchSend(consumed: false, empty: false),
        false,
      );
      expect(resolvePendingPaths(null), []);
      expect(resolvePendingPaths(['a']), ['a']);
      expect(shouldPauseBroadcast('paused'), true);
      expect(shouldPauseBroadcast('resumed'), false);
      expect(
        needsBroadcastRestart(isNull: true, isActive: false),
        true,
      );
      expect(
        needsBroadcastRestart(isNull: false, isActive: true),
        false,
      );
      expect(resolveFgColor(fg: null), 0xFF07C160);
      expect(resolveFgColor(fg: 1), 1);
      expect(hasNoDevices(isEmpty: true), true);
      expect(hasOpenChat(<String>{}), false);
      expect(hasOpenChat({'a'}), true);
      expect(hasNoLocalIp(null), true);
      expect(hasNoLocalIp('1.1.1.1'), false);
      expect(cacheLoadedLog(2), contains('2'));
      expect(hasNoSpace('noSpace'), true);
      expect(hasNoSpace(null), false);
      expect(isTrustedResult(true), true);
      expect(isTrustedResult(false), false);
      expect(isRejectedResult(false), true);
      expect(isRejectedResult(true), false);
      expect(matchesDeviceKey('a', 'a'), true);
      expect(matchesDeviceKey('a', 'b'), false);
    });
  });

  group('JK批收敛', () {
    test('app_clock固定值透传+默认非零', () {
      expect(app_clock.nowMs(fixed: 123), 123);
      expect(app_clock.nowUs(fixed: 456), 456);
      final fixed = DateTime(2026, 10, 9, 12);
      expect(app_clock.now(fixed: fixed), fixed);
      expect(app_clock.nowMs() > 0, true);
      expect(app_clock.nowUs() > 0, true);
    });

    test('delay_policy返回正值Duration', () {
      expect(delay_policy.ackGap().inMicroseconds > 0, true);
      expect(delay_policy.panelDebounce().inMicroseconds > 0, true);
      expect(delay_policy.scrollAnim().inMicroseconds > 0, true);
      expect(delay_policy.bubbleHide().inMicroseconds > 0, true);
      expect(delay_policy.recordTick().inMicroseconds > 0, true);
    });

    ChatMessage oldMsg([String content = '原文']) => ChatMessage(
          id: 'jk1',
          senderId: 'peer',
          content: content,
          type: MessageType.file,
          timestamp: DateTime(2026, 10, 9),
          isMe: false,
          transferState: TransferState.pending,
        );

    void expectFailed(ChatMessage got, String key) {
      expect(got.transferState, TransferState.failed);
      expect(got.content, contains(key));
    }

    test('markTextFailed原文包失败文案', () {
      final got = TransferTexts.markTextFailed(oldMsg(), 'hi');
      expect(got.transferState, TransferState.failed);
      expect(got.content, contains('hi'));
      expect(got.content, contains('发送失败'));
    });

    test('markFailedKeepContent沿用原文仅标失败', () {
      final got = TransferTexts.markFailedKeepContent(oldMsg('keep'));
      expect(got.transferState, TransferState.failed);
      expect(got.content, 'keep');
    });

    test('markInterrupted中断文案', () {
      expectFailed(
        TransferTexts.markInterrupted(oldMsg(), '📤 发送中断: a.txt'),
        '发送中断',
      );
    });

    test('markReject对方拒绝文案', () {
      expectFailed(
        TransferTexts.markReject(oldMsg(), '📤 对方拒绝接收: a.txt'),
        '对方拒绝',
      );
    });

    test('markSelfReject本人拒绝文案', () {
      expectFailed(
        TransferTexts.markSelfReject(oldMsg(), '📥 已拒绝接收: a.txt'),
        '已拒绝',
      );
    });

    test('markCancelLocal本地取消文案', () {
      expectFailed(
        TransferTexts.markCancelLocal(oldMsg(), '📥 已取消接收: a.txt'),
        '已取消',
      );
    });

    test('markPeerCancel对端取消文案', () {
      expectFailed(
        TransferTexts.markPeerCancel(oldMsg(), '📤 对方已取消: a.txt'),
        '对方已取消',
      );
    });

    test('markFileDeleted文件删除文案', () {
      expectFailed(
        TransferTexts.markFileDeleted(oldMsg(), '📤 文件已删除: a.txt'),
        '文件已删除',
      );
    });

    test('markSendFailure握手失败文案', () {
      expectFailed(
        TransferTexts.markSendFailure(oldMsg(), '📤 等待超时: a.txt'),
        '等待超时',
      );
    });

    test('markSendException异常文案', () {
      expectFailed(
        TransferTexts.markSendException(oldMsg(), '📤 发送失败: a.txt\nboom'),
        '发送失败',
      );
    });

    test('markAudioMissing/markAudioSendFailed语音文案', () {
      expectFailed(
        TransferTexts.markAudioMissing(oldMsg(), '语音消息（文件缺失）'),
        '语音消息',
      );
      expectFailed(
        TransferTexts.markAudioSendFailed(oldMsg(), '语音消息（发送失败）'),
        '语音消息',
      );
    });

    test('markAudioHandshake/markAudioLabel语音恒定标签', () {
      expectFailed(
        TransferTexts.markAudioHandshake(oldMsg(), '语音消息（对方已拒绝）'),
        '语音消息',
      );
      expectFailed(
        TransferTexts.markAudioLabel(oldMsg(), '语音消息'),
        '语音消息',
      );
    });

    test('markExtractAborted/markFailedWithContent带内容失败', () {
      expectFailed(
        TransferTexts.markExtractAborted(oldMsg(), '文件夹过大，已停止解压（d.zip）'),
        '停止解压',
      );
      expectFailed(
        TransferTexts.markFailedWithContent(oldMsg(), '📥 接收失败: a.txt'),
        '接收失败',
      );
    });
  });

  group('O批收敛', () {
    test('zipEntryBytes透传List非List回null', () {
      expect(FolderArchiveService.zipEntryBytes([1, 2]), [1, 2]);
      expect(FolderArchiveService.zipEntryBytes('x'), isNull);
      expect(FolderArchiveService.zipEntryBytes(null), isNull);
      expect(FolderArchiveService.zipEntryBytes(123), isNull);
    });

    test('send_naming断言与回退', () {
      expect(requireResendPath('p'), 'p');
      expect(() => requireResendPath(null), throwsA(anything));
      expect(nullableId('a'), 'a');
      expect(nullableId(null), isNull);
      expect(requireExistingId('id'), 'id');
      expect(() => requireExistingId(null), throwsA(anything));
      expect(taskMsgIdOr('t1', 'fb'), 'send_t1');
      expect(taskMsgIdOr(null, 'fb'), 'fb');
      expect(fileNameOrFolder(null), 'folder');
      expect(fileNameOrFolder('a'), 'a');
    });

    test('bubble_meta类型与重发分支抽样', () {
      expect(requirePreviewPath('p'), 'p');
      expect(() => requirePreviewPath(null), throwsA(anything));
      expect(isTextMessageType('text'), true);
      expect(isTextMessageType('image'), false);
      expect(isImageMessageType('image'), true);
      expect(isFileMessageType('file'), true);
      expect(isFileMessageType('text'), false);
      expect(
        resolveResendContent(isAudio: true, audioLabel: 'a', sendContent: 's'),
        'a',
      );
      expect(
        resolveResendContent(isAudio: false, audioLabel: 'a', sendContent: 's'),
        's',
      );
      expect(shouldShowImageBubble(isImage: true, imagePath: 'p'), true);
      expect(shouldShowImageBubble(isImage: true, imagePath: null), false);
      expect(shouldShowImageBubble(isImage: false, imagePath: 'p'), false);
    });

    test('bubbleEdgeBottom箭头在上贴边', () {
      expect(bubbleEdgeBottom(arrowOnTop: true, arrowH: 7), 0);
      expect(bubbleEdgeBottom(arrowOnTop: false, arrowH: 7), 7);
    });

    test('device_lookup回退与门控', () {
      expect(broadcastCmdOf({'cmd': 'hi'}), 'hi');
      expect(broadcastCmdOf({}), '');
      expect(resolveMdnsUdpPort(null, 8080), 8080);
      expect(resolveMdnsUdpPort(9000, 8080), 9000);
      expect(isTcpFallback(1, 2), true);
      expect(isTcpFallback(1, 1), false);
      expect(shouldShowNotify('silent'), false);
      expect(shouldShowNotify('text'), true);
    });

    test('arrival_texts回退与拒绝判定', () {
      expect(resolveLastMsg('cur', 'fb'), 'cur');
      expect(resolveLastMsg(null, 'fb'), 'fb');
      expect(isExplicitReject(false), true);
      expect(isExplicitReject(true), false);
      expect(isExplicitReject(null), false);
      expect(resolveSessIndex(1, {'fileIndex': 2}), 1);
      expect(resolveSessIndex(null, {'fileIndex': 2}), 2);
      expect(resolveSessIndex(null, null), isNull);
      expect(resolveSessId('d', {'sessionId': 'm'}), 'd');
      expect(resolveSessId(null, {'sessionId': 'm'}), 'm');
      expect(isNoSpaceReject('noSpace'), true);
      expect(isNoSpaceReject('other'), false);
    });

    test('device_merge匹配与计数', () {
      expect(matchesIp(id: '1.1.1.1', curIp: null, ip: '1.1.1.1'), true);
      expect(matchesIp(id: 'a', curIp: '1.1.1.1', ip: '1.1.1.1'), true);
      expect(matchesIp(id: 'a', curIp: 'b', ip: 'c'), false);
      expect(isLegacyKey('a', 'b'), true);
      expect(isLegacyKey('a', 'a'), false);
      expect(resolveStorageSavePath('默认文件夹'), '');
      expect(resolveStorageSavePath('d'), 'd');
      expect(deviceCount([1, 2]), 2);
      expect(sameBroadcast('a', 'a'), true);
      expect(sameBroadcast('a', 'b'), false);
    });

    test('send_path_classify可发送判定与门控', () {
      expect(isSendableTypeName('file'), true);
      expect(isSendableTypeName('directory'), true);
      expect(isSendableTypeName('other'), false);
      expect(isSendableEntityType(FileSystemEntityType.file), true);
      expect(isSendableEntityType(FileSystemEntityType.directory), true);
      expect(isSendableEntityType(FileSystemEntityType.link), false);
      expect(abortDrop(empty: true, mounted: true), true);
      expect(abortDrop(empty: false, mounted: false), true);
      expect(abortDrop(empty: false, mounted: true), false);
      expect(nullablePathsOrNull([]), isNull);
      expect(nullablePathsOrNull(['a']), ['a']);
    });

    test('fallbackFileKey拼接', () {
      expect(fallbackFileKey('1.1.1.1', 'a.txt'), '1.1.1.1_a.txt');
    });

    test('deviceDebugLabel拼接', () {
      expect(chat_list_logs.deviceDebugLabel('n', 'id'), ' n(id)');
    });

    test('device_tile_meta状态抽样', () {
      expect(isResumedState('resumed'), true);
      expect(isResumedState('paused'), false);
      expect(isBroadcastActive(hasTimer: true, isActive: true), true);
      expect(isBroadcastActive(hasTimer: true, isActive: false), false);
      expect(isBroadcastActive(hasTimer: false, isActive: true), false);
      expect(hasDragHighlight(true), true);
      expect(hasDragHighlight(false), false);
      expect(tileAvatarSize(), 48.0);
    });

    test('P批cmd/status/manual判定收敛', () {
      expect(isFileCancelCmd('fileCancel'), true);
      expect(isFileCancelCmd('blockSync'), false);
      expect(isBlockSyncCmd('blockSync'), true);
      expect(isBlockSyncCmd('fileNotify'), false);
      expect(isFileNotifyCmd('fileNotify'), true);
      expect(isFileNotifyCmd('textMessage'), false);
      expect(isOfflineStatus('offline'), true);
      expect(isOfflineStatus('online'), false);
      expect(isManualOnlineLabel('online'), true);
      expect(isManualOnlineLabel('unknown'), false);
      expect(isManualOnline(true), true);
      expect(isManualOnline(false), false);
      expect(tileFgColorOrGrey(0xFF123456), 0xFF123456);
      expect(tileFgColorOrGrey(null), 0xFF9E9E9E);
    });

    test('E3缓存加密 seal/open 往返与降级', () {
      const key = 'a2V5XzMyX2J5dGVzX2Jhc2U2NF9mb3JfdGVzdA==';
      const json = '[{"id":"m1","content":"秘密消息"}]';
      // 加密往返
      final sealed = sealPayload(json, key);
      expect(sealed.startsWith('enc1:'), true);
      expect(sealed, isNot(contains('秘密消息')));
      expect(openPayload(sealed, key), json);
      // 无前缀历史明文行原样放行（渐进迁移）
      expect(openPayload(json, key), json);
      // 密钥为空：seal 原样返回（降级明文）；open 拒放行密文
      expect(sealPayload(json, ''), json);
      expect(openPayload(sealed, ''), isNull);
      // 错误密钥：tag 校验失败返回 null
      expect(openPayload(sealed, 'wrong_key_wrong_key_wrong_key!!'), isNull);
      // 随机 iv：同输入两次 seal 密文不同
      expect(sealPayload(json, key), isNot(sealPayload(json, key)));
    });
  });
}