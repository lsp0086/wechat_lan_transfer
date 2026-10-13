// E1/U2：待发送路径归类。从 ChatListPage._maybeConsumeLaunchSend（启动参数）与
// _handleDroppedFiles（桌面拖拽）抽出的纯函数，可单测。
// 约定：目录只取第一个（打包 zip 由 ChatPage 处理），文件按存在性过滤。

import 'dart:io';

/// 归类结果：files 为待直发/批量文件，folderPath 为待打包目录（可空）。
typedef ClassifiedSendPaths = ({List<String> files, String? folderPath});

/// 按类型回调归类：[kinds] 与 paths 等长，'dir' 视为目录，其余视为文件。
/// [exists] 文件存在性检查（默认恒真，IO 由调用方做）。
ClassifiedSendPaths classifySendPaths({
  required List<String> paths,
  required List<String> kinds,
  bool Function(String path)? exists,
}) {
  final files = <String>[];
  String? folderPath;
  final check = exists ?? (_) => true;
  for (var i = 0; i < paths.length; i++) {
    final p = paths[i];
    final kind = i < kinds.length ? kinds[i] : 'file';
    if (kind == 'dir') {
      folderPath ??= p;
      continue;
    }
    if (p.isEmpty || !check(p)) continue;
    files.add(p);
  }
  return (files: files, folderPath: folderPath);
}

/// 是否有可发送内容。
bool hasSendContent(ClassifiedSendPaths c) =>
    c.files.isNotEmpty || c.folderPath != null;

// E1：空路径列表转 null 收敛（宿主 pendingFilePaths 用）。
List<String>? nullablePathsOrNull(List<String> paths) =>
    paths.isEmpty ? null : paths;

// E1：启动发送消费门控收敛（已消费或空路径即跳过）。
bool shouldSkipLaunchSend({required bool consumed, required bool empty}) =>
    consumed || empty;

// E1：待发路径回退收敛（null 回空列表）。
List<String> resolvePendingPaths(List<String>? p) => p ?? const [];

// E1：拖拽丢弃门控收敛（空列表或未挂载即中止，IO 检查留宿主）。
bool abortDrop({required bool empty, required bool mounted}) =>
    empty || !mounted;

// E1：可发送实体类型名判定收敛（file/directory 才发送，枚举名透传）。
bool isSendableTypeName(String n) => n == 'file' || n == 'directory';

// E1：可发送实体类型判定收敛（file/directory 才发送）。
bool isSendableEntityType(FileSystemEntityType t) =>
    t == FileSystemEntityType.file || t == FileSystemEntityType.directory;
