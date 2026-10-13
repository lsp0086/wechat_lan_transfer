// 传输层通用文件工具（从 file_transfer_service.dart 迁移的纯函数/纯 IO）。
// 不依赖旧 TCP/TLS 管线，供 ls_server / UI 复用。

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wechat_lan_transfer/Services/free_space.dart';

/// 清洗对端传来的文件名，防止路径穿越（P0-2）。
/// 取 basename，拒绝 `/ \ ..`，白名单替换非法字符，超长截断。
String lsSanitizeFileName(String raw) {
  var name = raw.replaceAll('\\', '/');
  final slashIdx = name.lastIndexOf('/');
  if (slashIdx != -1) {
    name = name.substring(slashIdx + 1);
  }
  name = name.trim();
  name = name.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '');
  name = name.replaceFirst(RegExp(r'^\.+'), '');
  name = name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
  if (name.isEmpty) return 'unnamed_file';
  if (name == '.' || name == '..') return 'unnamed_file';
  if (name.length > 200) {
    final dot = name.lastIndexOf('.');
    if (dot > 0 && name.length - dot <= 20) {
      name =
          '${name.substring(0, 200 - (name.length - dot))}${name.substring(dot)}';
    } else {
      name = name.substring(0, 200);
    }
  }
  return name;
}

/// 按 UTF-8 字节截断文件名（保留扩展名，截断后加 `…`）。
String lsFitFileName(String raw, {int maxBytes = 180}) {
  final name = lsSanitizeFileName(raw);
  if (utf8.encode(name).length <= maxBytes) return name;
  final dot = name.lastIndexOf('.');
  final ext = (dot > 0 && name.length - dot <= 16) ? name.substring(dot) : '';
  final base = ext.isEmpty ? name : name.substring(0, dot);
  final extBytes = utf8.encode(ext).length;
  final budget = maxBytes - extBytes - 3; // 3 = '…'
  if (budget <= 0) return 'unnamed_file$ext';
  final kept = StringBuffer();
  var used = 0;
  for (final rune in base.runes) {
    final ch = String.fromCharCode(rune);
    final n = utf8.encode(ch).length;
    if (used + n > budget) break;
    kept.write(ch);
    used += n;
  }
  final out = '${kept.toString()}…$ext';
  return utf8.encode(out).length <= maxBytes ? out : 'unnamed_file$ext';
}

/// 流式计算文件 SHA-256（hex），大文件不全量进内存。
Future<String> lsSha256OfFile(String path) async {
  final file = File(path);
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

/// 按最终路径规则解析保存路径（含 `base (1).ext` 冲突命名），不建文件。
Future<String> lsResolveSavePath(String dirPath, String safeName) async {
  String saveName = safeName;
  String savePath = '$dirPath/$saveName';
  int counter = 1;
  while (await File(savePath).exists()) {
    final ext = safeName.contains('.')
        ? safeName.substring(safeName.lastIndexOf('.'))
        : '';
    final baseName = safeName.contains('.')
        ? safeName.substring(0, safeName.lastIndexOf('.'))
        : safeName;
    saveName = '$baseName ($counter)$ext';
    savePath = '$dirPath/$saveName';
    counter++;
  }
  return savePath;
}

/// 启动时清理残留半文件：.tmp/.bak 常清；近期 .part 保留（v2 无续传但保留
/// 防误删进行中会话），仅删 7 天以上陈旧文件。失败只打日志。
Future<void> lsCleanupPartialFiles(String dirPath) async {
  try {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return;
    var removed = 0;
    final now = DateTime.now();
    await for (final e in dir.list()) {
      if (e is! File) continue;
      final p = e.path;
      final isTmp = p.endsWith('.tmp');
      final isBak = p.endsWith('.bak');
      final isPart = p.endsWith('.part');
      if (!isTmp && !isBak && !isPart) continue;
      if (isPart || isBak) {
        try {
          final stat = await e.stat();
          if (now.difference(stat.modified).inDays < 7) continue;
        } catch (_) {}
      }
      try {
        await e.delete();
        removed++;
      } catch (_) {}
    }
    if (removed > 0) {
      debugPrint('[LsTransfer] 启动清理半文件 $removed 个: $dirPath');
    }
  } catch (e) {
    debugPrint('[LsTransfer] 清理半文件失败: $e');
  }
}

/// 接收存储管理：保存目录 + 空间预检 + 落盘路径解析。
class LsStorage {
  String? _saveDirectory;

  String? get saveDirectory => _saveDirectory;

  /// 运行时更新保存目录（用户设置变更）。
  void setSaveDirectory(String path) {
    _saveDirectory = path;
    debugPrint('[LsTransfer] 保存目录已更新: $path');
  }

  /// 确保保存目录存在并返回其路径。
  Future<String> ensureSaveDir() async {
    final saveDir = _saveDirectory ?? await defaultSaveDir();
    final dir = Directory(saveDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  /// 空间预检。返回 null 表示可收，否则返回人类可读原因。
  Future<String?> precheckSpace(String fileName, int fileSize) async {
    try {
      final dirPath = await ensureSaveDir();
      final free = await FreeSpace.of(dirPath);
      if (free != null) {
        if (free <= fileSize) {
          throw Exception('磁盘空间不足（剩余 $free 字节，需 $fileSize 字节）');
        }
        return null;
      }
      // 无 statvfs：哨兵可写探测兜底。
      final probe = File(
          '$dirPath/.wlan_space_probe_${DateTime.now().microsecondsSinceEpoch}');
      try {
        await probe.create(recursive: true);
        await probe.delete();
      } catch (e) {
        throw Exception('磁盘空间不足或目录不可写 ($e)');
      }
      return null;
    } catch (e) {
      debugPrint('[LsTransfer] 空间预检不通过: $fileName ($e)');
      return '对方空间不足，无法接收: $fileName';
    }
  }

  /// 为一个待接收文件解析最终落盘路径（含冲突命名）。
  Future<String> resolveSavePath(String safeName) async {
    final dirPath = await ensureSaveDir();
    return lsResolveSavePath(dirPath, safeName);
  }
}

/// 默认保存目录（各平台 Download/文档目录）。
Future<String> defaultSaveDir() async {
  if (Platform.isAndroid) {
    try {
      final extDir = await getExternalStorageDirectory();
      if (extDir != null) {
        final downloadDir = Directory(
          '${extDir.path}/../../../../Download/WeChatLanTransfer',
        );
        if (await downloadDir.parent.exists()) {
          return downloadDir.path;
        }
        final altDownloadDir = Directory(
          '/storage/emulated/0/Download/WeChatLanTransfer',
        );
        if (await altDownloadDir.parent.exists()) {
          return altDownloadDir.path;
        }
      }
    } catch (_) {}
    final appDocDir = await getApplicationDocumentsDirectory();
    return '${appDocDir.path}/WeChatLanTransfer';
  } else if (Platform.isIOS) {
    final docDir = await getApplicationDocumentsDirectory();
    return '${docDir.path}/WeChatLanTransfer';
  } else if (Platform.isWindows) {
    String? downloadsPath;
    try {
      final dir = await getDownloadsDirectory();
      downloadsPath = dir?.path;
    } catch (_) {}
    if (downloadsPath != null && downloadsPath.isNotEmpty) {
      return '$downloadsPath\\WeChatLanTransfer';
    }
    final userProfile = Platform.environment['USERPROFILE'] ?? '.';
    return '$userProfile\\Downloads\\WeChatLanTransfer';
  } else if (Platform.isMacOS) {
    String? downloadsPath;
    try {
      final dir = await getDownloadsDirectory();
      downloadsPath = dir?.path;
    } catch (_) {}
    if (downloadsPath != null && downloadsPath.isNotEmpty) {
      return '$downloadsPath/WeChatLanTransfer';
    }
    return '${Platform.environment['HOME'] ?? '.'}/Downloads/WeChatLanTransfer';
  } else if (Platform.isLinux) {
    String? downloadsPath;
    try {
      final dir = await getDownloadsDirectory();
      downloadsPath = dir?.path;
    } catch (_) {}
    if (downloadsPath != null && downloadsPath.isNotEmpty) {
      return '$downloadsPath/WeChatLanTransfer';
    }
    return '${Platform.environment['HOME'] ?? '.'}/Downloads/WeChatLanTransfer';
  }
  final appDocDir = await getApplicationDocumentsDirectory();
  return '${appDocDir.path}/WeChatLanTransfer';
}

// ================ Windows 防火墙 ================

const String _lsFirewallRuleName = 'WeChatLANTransfer';

/// 检测 Windows 防火墙规则是否已存在（需要管理员权限）。
Future<bool> lsIsFirewallRuleExists() async {
  if (!Platform.isWindows) return true;
  try {
    final result = await Process.run('netsh', [
      'advfirewall',
      'firewall',
      'show',
      'rule',
      'name=$_lsFirewallRuleName',
    ]);
    return result.exitCode == 0 &&
        result.stdout.toString().contains(_lsFirewallRuleName);
  } catch (_) {
    return false;
  }
}

/// 添加 Windows 防火墙入站规则（v2：TCP 53317 + UDP 53317）。
/// 应用已通过 manifest 提权，此方法应直接生效。
Future<bool> lsFixWindowsFirewall({
  int port = 53317,
  int udpPort = 53317,
}) async {
  if (!Platform.isWindows) return true;

  Future<bool> addRule({
    required String name,
    required String protocol,
    required int localPort,
  }) async {
    try {
      final result = await Process.run('netsh', [
        'advfirewall',
        'firewall',
        'add',
        'rule',
        'name=$name',
        'dir=in',
        'action=allow',
        'protocol=$protocol',
        'localport=$localPort',
        'profile=any',
      ]);
      if (result.exitCode == 0) {
        debugPrint('[Firewall] $name 已添加（或已存在）');
        return true;
      }
      debugPrint(
          '[Firewall] $name 添加失败: exitCode=${result.exitCode} stderr=${result.stderr}');
      return false;
    } catch (e) {
      debugPrint('[Firewall] $name 异常: $e');
      return false;
    }
  }

  final tcpOk = await addRule(
    name: '$_lsFirewallRuleName-TCP',
    protocol: 'TCP',
    localPort: port,
  );
  final udpOk = await addRule(
    name: '$_lsFirewallRuleName-UDP',
    protocol: 'UDP',
    localPort: udpPort,
  );
  return tcpOk && udpOk;
}
