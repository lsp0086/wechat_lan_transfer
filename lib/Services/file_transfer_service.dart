import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 传输状态枚举
enum TransferStatus {
  pending,    // 等待中
  connecting, // 连接中
  transferring, // 传输中
  completed,  // 已完成
  failed,     // 失败
  cancelled,  // 已取消
  received,   // 已接收（对方发来的）
}

/// 文件传输任务
class FileTransferTask {
  final String id;
  final String fileName;
  final String filePath;
  final int fileSize;
  final String targetIp;
  final int port;
  final bool isSender; // true=我是发送方
  TransferStatus status;
  double progress; // 0.0 ~ 1.0
  String? errorMessage;
  String? savedPath; // 接收方保存路径

  FileTransferTask({
    required this.id,
    required this.fileName,
    required this.filePath,
    required this.fileSize,
    required this.targetIp,
    required this.port,
    required this.isSender,
    this.status = TransferStatus.pending,
    this.progress = 0.0,
    this.errorMessage,
    this.savedPath,
  });
}

/// 文件传输服务：基于 TCP 的文件发送/接收引擎
class FileTransferService {
  static const int defaultPort = 8899;
  static const int headerSize = 1024; // 头部信息大小（文件名等元数据）

  ServerSocket? _server;
  bool _isServerRunning = false;
  String? _saveDirectory;

  // 活跃传输任务
  final Map<String, FileTransferTask> _activeTasks = {};
  // 进度流控制器
  final StreamController<FileTransferTask> _progressController =
      StreamController<FileTransferTask>.broadcast();
  // 新任务通知流
  final StreamController<FileTransferTask> _newTaskController =
      StreamController<FileTransferTask>.broadcast();

  Stream<FileTransferTask> get progressStream => _progressController.stream;
  Stream<FileTransferTask> get newTaskStream => _newTaskController.stream;

  Map<String, FileTransferTask> get activeTasks => Map.unmodifiable(_activeTasks);

  /// 启动文件接收服务器
  Future<void> startServer({String? saveDir}) async {
    if (_isServerRunning) return;
    _saveDirectory = saveDir ?? await _getDefaultSaveDir();

    // 确保保存目录存在
    final dir = Directory(_saveDirectory!);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    try {
      _server = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        defaultPort,
      );
      _isServerRunning = true;
      debugPrint('文件接收服务器已启动，监听端口: $defaultPort，保存路径: $_saveDirectory');

      _server!.listen((Socket client) {
        _handleIncomingConnection(client);
      });
    } catch (e) {
      debugPrint('启动文件接收服务器失败: $e');
      _isServerRunning = false;
    }
  }

  /// 停止服务器
  void stopServer() {
    _server?.close();
    _server = null;
    _isServerRunning = false;
  }

  /// 发送文件到目标设备
  Future<FileTransferTask?> sendFile({
    required String filePath,
    required String targetIp,
    String? customFileName,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('文件不存在: $filePath');
    }

    final fileName = customFileName ?? filePath.split('/').last.split('\\').last;
    final fileSize = await file.length();
    final taskId = 'send_${DateTime.now().millisecondsSinceEpoch}';

    final task = FileTransferTask(
      id: taskId,
      fileName: fileName,
      filePath: filePath,
      fileSize: fileSize,
      targetIp: targetIp,
      port: defaultPort,
      isSender: true,
    );

    _activeTasks[taskId] = task;
    _progressController.add(task);

    try {
      task.status = TransferStatus.connecting;
      _progressController.add(task);

      final socket = await Socket.connect(
        targetIp,
        defaultPort,
        timeout: const Duration(seconds: 10),
      );

      task.status = TransferStatus.transferring;
      _progressController.add(task);

      // 发送文件头信息（JSON + 填充到 headerSize）
      final header = jsonEncode({
        'fileName': fileName,
        'fileSize': fileSize,
        'taskId': taskId,
      });
      final headerBytes = utf8.encode(header);
      final paddedHeader = Uint8List(headerSize);
      paddedHeader.fillRange(0, headerBytes.length > headerSize ? headerSize : headerBytes.length, 0);
      for (int i = 0; i < headerBytes.length && i < headerSize; i++) {
        paddedHeader[i] = headerBytes[i];
      }
      // 在末尾写入实际头长度
      final headerLenBytes = ByteData(4)..setInt32(0, headerBytes.length, Endian.big);
      socket.add(paddedHeader);
      socket.add(headerLenBytes.buffer.asUint8List());

      // 发送文件内容，带进度回调
      final fileStream = file.openRead();
      int bytesSent = 0;

      await for (final chunk in fileStream) {
        socket.add(chunk);
        bytesSent += chunk.length;
        task.progress = bytesSent / fileSize;
        _progressController.add(task);
      }

      await socket.flush();
      await socket.close();

      task.status = TransferStatus.completed;
      task.progress = 1.0;
      _progressController.add(task);

      debugPrint('文件发送完成: $fileName');
      return task;
    } catch (e) {
      task.status = TransferStatus.failed;
      task.errorMessage = e.toString();
      _progressController.add(task);
      debugPrint('文件发送失败: $e');
      return task;
    }
  }

  /// 处理接收连接
  Future<void> _handleIncomingConnection(Socket client) async {
    FileTransferTask? task;
    String filePath = '';

    try {
      // 读取文件头
      final headerBuffer = await _readExactly(client, headerSize + 4);

      // 解析头长度
      final headerLenData = headerBuffer.buffer.asByteData(
        headerSize,
        4,
      );
      final headerLen = headerLenData.getInt32(0, Endian.big);

      // 解析 JSON 头
      final headerJson = utf8.decode(
        headerBuffer.sublist(0, headerLen > headerSize ? headerSize : headerLen),
      );
      final header = jsonDecode(headerJson) as Map<String, dynamic>;
      final fileName = header['fileName'] as String;
      final fileSize = header['fileSize'] as int;
      final taskId = header['taskId'] as String;

      // 创建保存路径
      final saveDir = _saveDirectory ?? await _getDefaultSaveDir();
      final dir = Directory(saveDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      // 防止文件名冲突
      String saveName = fileName;
      String savePath = '${dir.path}/$saveName';
      int counter = 1;
      while (await File(savePath).exists()) {
        final ext = fileName.contains('.')
            ? fileName.substring(fileName.lastIndexOf('.'))
            : '';
        final baseName = fileName.contains('.')
            ? fileName.substring(0, fileName.lastIndexOf('.'))
            : fileName;
        saveName = '$baseName($counter)$ext';
        savePath = '${dir.path}/$saveName';
        counter++;
      }

      task = FileTransferTask(
        id: taskId,
        fileName: fileName,
        filePath: savePath,
        fileSize: fileSize,
        targetIp: client.address.address,
        port: defaultPort,
        isSender: false,
        status: TransferStatus.transferring,
      );

      _activeTasks[taskId] = task;
      _newTaskController.add(task);
      _progressController.add(task);

      // 接收文件内容
      final saveFile = File(savePath);
      final sink = saveFile.openWrite();
      int bytesReceived = 0;

      try {
        await for (final chunk in client) {
          sink.add(chunk);
          bytesReceived += chunk.length;
          task.progress = bytesReceived / fileSize;
          _progressController.add(task);
        }
      } finally {
        await sink.close();
      }

      task.status = TransferStatus.completed;
      task.progress = 1.0;
      task.savedPath = savePath;
      _progressController.add(task);

      debugPrint('文件接收完成: $fileName -> $savePath');
    } catch (e) {
      debugPrint('文件接收失败: $e');
      if (task != null) {
        task.status = TransferStatus.failed;
        task.errorMessage = e.toString();
        _progressController.add(task);
      }
      // 清理未完成的文件（task 为 null 说明头解析失败，文件可能已部分写入）
      if (task == null && filePath.isNotEmpty) {
        try {
          await File(filePath).delete();
        } catch (_) {}
      }
    } finally {
      try {
        await client.close();
      } catch (_) {}
    }
  }

  /// 精确读取指定字节数
  Future<Uint8List> _readExactly(Socket socket, int byteCount) async {
    final buffer = Uint8List(byteCount);
    int offset = 0;
    while (offset < byteCount) {
      final chunk = await socket.first;
      final toCopy = (chunk.length <= byteCount - offset)
          ? chunk.length
          : byteCount - offset;
      buffer.setRange(offset, offset + toCopy, chunk);
      offset += toCopy;
      if (offset >= byteCount) break;
    }
    return buffer;
  }

  /// 取消传输
  void cancelTransfer(String taskId) {
    final task = _activeTasks[taskId];
    if (task != null) {
      task.status = TransferStatus.cancelled;
      _progressController.add(task);
      _activeTasks.remove(taskId);
    }
  }

  /// 获取默认保存目录（使用 path_provider 获取各平台正确的下载/文档路径）
  Future<String> _getDefaultSaveDir() async {
    if (Platform.isAndroid) {
      // Android: 使用外部存储的 Download 目录
      // path_provider 的 getExternalStorageDirectory 在不同 Android 版本行为不同
      // 优先使用 downloads 目录，回退到应用外部存储目录
      try {
        final extDir = await getExternalStorageDirectory();
        if (extDir != null) {
          // 典型路径: /storage/emulated/0/Android/data/.../files
          // 向上一级到 Download 目录
          final downloadDir = Directory('${extDir.path}/../../../../Download/WeChatLanTransfer');
          if (await downloadDir.parent.exists()) {
            return downloadDir.path;
          }
          // 回退：使用外部存储根目录下的 Download
          final altDownloadDir = Directory('/storage/emulated/0/Download/WeChatLanTransfer');
          if (await altDownloadDir.parent.exists()) {
            return altDownloadDir.path;
          }
        }
      } catch (_) {}
      // 最终回退：应用文档目录
      final appDocDir = await getApplicationDocumentsDirectory();
      return '${appDocDir.path}/WeChatLanTransfer';
    } else if (Platform.isIOS) {
      // iOS: 使用应用 Documents 目录（用户可访问的沙盒目录）
      final docDir = await getApplicationDocumentsDirectory();
      return '${docDir.path}/WeChatLanTransfer';
    } else if (Platform.isWindows) {
      // Windows: 使用 Downloads 目录
      final downloadsPath = await getDownloadsDirectory();
      if (downloadsPath != null) {
        return '$downloadsPath\\WeChatLanTransfer';
      }
      // 回退
      return '${Platform.environment['USERPROFILE'] ?? '.'}\\Downloads\\WeChatLanTransfer';
    } else if (Platform.isMacOS) {
      // macOS: 使用 Downloads 目录
      final downloadsPath = await getDownloadsDirectory();
      if (downloadsPath != null) {
        return '$downloadsPath/WeChatLanTransfer';
      }
      return '${Platform.environment['HOME'] ?? '.'}/Downloads/WeChatLanTransfer';
    } else if (Platform.isLinux) {
      // Linux: 使用 Downloads 目录
      final downloadsPath = await getDownloadsDirectory();
      if (downloadsPath != null) {
        return '$downloadsPath/WeChatLanTransfer';
      }
      return '${Platform.environment['HOME'] ?? '.'}/Downloads/WeChatLanTransfer';
    } else {
      // 未知平台回退
      final appDocDir = await getApplicationDocumentsDirectory();
      return '${appDocDir.path}/WeChatLanTransfer';
    }
  }

  void dispose() {
    stopServer();
    _progressController.close();
    _newTaskController.close();
  }
}
