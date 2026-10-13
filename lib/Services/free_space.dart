// T4：分区真实剩余空间。macOS/Linux 走 df -k -P（POSIX 固定 6 列），
// Windows 走 PowerShell Get-PSDrive；Android 走 statvfs FFI（bionic，无沙盒
// 配额硬约束——/storage/emulated/0 经 FUSE 上报共享卷剩余，普通应用无独立配额）；
// iOS 无标准通道仍返回 null，由调用方回退哨兵可写探测
// （file_transfer_service._checkFreeSpace）。解析为纯函数可单测。

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' show calloc;

class FreeSpace {
  FreeSpace._();

  /// 查询 [dirPath] 所在分区的剩余空间（字节）；拿不到返回 null。
  static Future<int?> of(String dirPath) async {
    try {
      if (Platform.isAndroid) {
        return statvfsFreeBytesAndroid(dirPath);
      }
      if (Platform.isMacOS || Platform.isLinux) {
        final r = await Process.run('df', ['-k', '-P', dirPath]);
        if (r.exitCode != 0) return null;
        return parseDfOutput(r.stdout.toString(), dirPath);
      }
      if (Platform.isWindows) {
        final drive = driveOf(dirPath);
        if (drive == null) return null;
        final r = await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          '(Get-PSDrive ${drive.substring(0, drive.length - 1)}).Free',
        ]);
        if (r.exitCode != 0) return null;
        final v = int.tryParse(r.stdout.toString().trim());
        return (v != null && v >= 0) ? v : null;
      }
    } catch (_) {}
    return null;
  }

  /// Windows 盘符（如 'C:'）；非盘符路径返回 null。
  static String? driveOf(String path) {
    final p = path.replaceAll('/', '\\');
    final m = RegExp(r'^([A-Za-z]):').firstMatch(p);
    return m == null ? null : '${m.group(1)!}:';
  }

  /// df -k -P 输出解析（纯函数）：目标行（含 [dirPath]，回退第二行）的
  /// Available 列（第 4 列，1K 块）×1024。POSIX 格式：Filesystem 1024-blocks
  /// Used Available Capacity Mounted on。
  static int? parseDfOutput(String out, String dirPath) {
    final lines = out
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (lines.length < 2) return null;
    String? row;
    for (final l in lines.skip(1)) {
      if (l.contains(dirPath)) {
        row = l;
        break;
      }
    }
    row ??= lines[1];
    final cols = row.trim().split(RegExp(r'\s+'));
    if (cols.length < 4) return null;
    final availK = int.tryParse(cols[3]);
    if (availK == null || availK < 0) return null;
    return availK * 1024;
  }

  // ===== Android statvfs FFI（T4 遗留，2026-10-12）=====
  //
  // bionic struct statvfs（NDK 28 sysroot 实测确认）：前 11 个字段均为
  // unsigned long（= 指针宽度），fsblkcnt_t 同为 unsigned long，
  // f_bavail 是第 5 个字段：offset = 4 × 指针宽度，宽度 = 指针宽度
  // （LP64 arm64-v8a/x86_64：偏移 32 宽 8；LP32 armeabi-v7a/x86：偏移 16 宽 4）。
  // bionic 的 statvfs64 与 statvfs 同布局（fsblkcnt_t 不随 64 位后缀加宽），
  // 故直接调 statvfs（API 21+）。
  static int? statvfsFreeBytesAndroid(String dirPath) {
    ffi.Pointer<ffi.Uint8>? path;
    ffi.Pointer<ffi.Uint8>? buf;
    try {
      final statvfs = ffi.DynamicLibrary.process()
          .lookupFunction<
            ffi.Int32 Function(
              ffi.Pointer<ffi.Uint8>,
              ffi.Pointer<ffi.Uint8>,
            ),
            int Function(ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>)
          >('statvfs');
      final units = utf8.encode(dirPath);
      path = calloc<ffi.Uint8>(units.length + 1);
      path.asTypedList(units.length + 1)
        ..setAll(0, units)
        ..[units.length] = 0;
      buf = calloc<ffi.Uint8>(256); // LP64 结构体 112B，留余量
      if (statvfs(path, buf) != 0) return null; // errno 置位 → 回退哨兵探测
      return parseBavail(buf.asTypedList(256), ffi.sizeOf<ffi.Pointer>());
    } catch (_) {
      return null;
    } finally {
      if (path != null) calloc.free(path);
      if (buf != null) calloc.free(buf);
    }
  }

  /// statvfs 缓冲按指针宽度读 f_bavail 字节数（纯函数，可单测）；
  /// 0 或超过 2^47（≈128TB）视为布局错位/异常，返回 null 走回退。
  static int? parseBavail(Uint8List bytes, int ptrSize) {
    try {
      final bd = ByteData.sublistView(bytes);
      final offset = 4 * ptrSize;
      final free = ptrSize == 8
          ? bd.getUint64(offset, Endian.little)
          : bd.getUint32(offset, Endian.little);
      if (free <= 0 || free > (1 << 47)) return null;
      return free;
    } catch (_) {
      return null;
    }
  }
}
