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

/// 接收初始化结果
class _ReceiveInitResult {
  final FileTransferTask task;
  final String savePath;
  final IOSink sink;
  _ReceiveInitResult({
    required this.task,
    required this.savePath,
    required this.sink,
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

      // 发送文件头信息（固定1024字节JSON头 + 4字节头长度）
      final header = jsonEncode({
        'fileName': fileName,
        'fileSize': fileSize,
        'taskId': taskId,
      });
      final headerBytes = utf8.encode(header);
      if (headerBytes.length > headerSize) {
        throw Exception('文件名过长，超出头部限制');
      }
      // 构造固定长度头部：JSON数据 + 零填充
      final paddedHeader = Uint8List(headerSize);
      paddedHeader.setRange(0, headerBytes.length, headerBytes);
      // 构造4字节的头长度标记（大端序）
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

  /// 处理接收连接（使用 Completer + listen 方式一次性处理头部和文件内容）
  Future<void> _handleIncomingConnection(Socket client) async {
    final completer = Completer<void>();
    FileTransferTask? task;
    String? savePath;
    IOSink? sink;

    // 状态机: 0=等待头部, 1=接收文件内容, 2=正在初始化接收任务
    int state = 0;
    final headerBuffer = <int>[];
    // 在 state=2 期间缓冲到达的文件数据块，初始化完成后一次性写入
    final List<List<int>> pendingChunks = [];
    int bytesReceived = 0;
    int expectedFileSize = 0;

    client.listen(
      (chunk) {
        try {
          if (state == 0) {
            // 阶段1: 收集头部数据
            headerBuffer.addAll(chunk);
            if (headerBuffer.length >= headerSize + 4) {
              // 立即切换到过渡状态，防止异步初始化期间重复解析头部
              state = 2; // 2 = 正在初始化接收任务

              // 头部收集完毕，解析
              final headerBytes = Uint8List.fromList(headerBuffer);
              final headerLenData = ByteData.sublistView(
                headerBytes, headerSize, headerSize + 4);
              final headerLen = headerLenData.getInt32(0, Endian.big);

              if (headerLen <= 0 || headerLen > headerSize) {
                debugPrint('文件接收失败: 非法头部长度 $headerLen');
                completer.completeError(
                  Exception('非法头部长度 $headerLen'));
                return;
              }

              final headerJson = utf8.decode(
                headerBytes.sublist(0, headerLen));
              final header =
                  jsonDecode(headerJson) as Map<String, dynamic>;
              final fileName = header['fileName'] as String;
              final fileSize = header['fileSize'] as int;
              final taskId = header['taskId'] as String;

              // 异步初始化保存路径和文件写入器
              _initReceiveTask(
                fileName: fileName,
                fileSize: fileSize,
                taskId: taskId,
                senderIp: client.address.address,
              ).then((initResult) {
                if (initResult == null) {
                  completer.completeError(
                    Exception('初始化接收任务失败'));
                  return;
                }
                task = initResult.task;
                savePath = initResult.savePath;
                sink = initResult.sink;
                expectedFileSize = fileSize;

                // 处理头部之后可能已接收的多余数据（属于文件内容）
                final extraData = headerBuffer.length > headerSize + 4
                    ? headerBuffer.sublist(headerSize + 4)
                    : null;
                if (extraData != null && extraData.isNotEmpty) {
                  sink!.add(extraData);
                  bytesReceived = extraData.length;
                }

                // 写入在 state=2 期间缓冲的数据块
                for (final bufferedChunk in pendingChunks) {
                  sink!.add(bufferedChunk);
                  bytesReceived += bufferedChunk.length;
                }
                pendingChunks.clear();

                if (task != null && bytesReceived > 0) {
                  task!.progress = bytesReceived / fileSize;
                  _progressController.add(task!);
                }

                state = 1;
              }).catchError((e) {
                completer.completeError(e);
              });
            }
          } else if (state == 1) {
            // 阶段2: 接收文件内容
            if (sink != null && task != null) {
              sink!.add(chunk);
              bytesReceived += chunk.length;
              task!.progress = bytesReceived / expectedFileSize;
              _progressController.add(task!);
            }
          } else {
            // state == 2: 正在异步初始化，缓冲到达的数据块
            pendingChunks.add(chunk.toList());
          }
        } catch (e) {
          debugPrint('接收数据处理异常: $e');
          if (!completer.isCompleted) {
            completer.completeError(e);
          }
        }
      },
      onError: (error) {
        debugPrint('Socket 接收错误: $error');
        if (!completer.isCompleted) {
          completer.completeError(error);
        }
      },
      onDone: () async {
        // 连接关闭，完成接收
        try {
          if (sink != null) {
            await sink!.close();
          }
        } catch (_) {}

        if (task != null && savePath != null) {
          if (bytesReceived >= expectedFileSize) {
            task!.status = TransferStatus.completed;
            task!.progress = 1.0;
            task!.savedPath = savePath;
            _progressController.add(task!);
            debugPrint(
              '文件接收完成: ${task!.fileName} -> $savePath '
              '(${_formatFileSize(expectedFileSize)})');
          } else {
            task!.status = TransferStatus.failed;
            task!.errorMessage =
              '传输中断 (接收 $bytesReceived/$expectedFileSize 字节)';
            _progressController.add(task!);
            debugPrint('文件接收不完整: ${task!.fileName}');
          }
        }

        if (!completer.isCompleted) {
          completer.complete();
        }
      },
      cancelOnError: false,
    );

    try {
      await completer.future;
    } catch (e) {
      debugPrint('文件接收失败: $e');
      if (task != null) {
        task!.status = TransferStatus.failed;
        task!.errorMessage = e.toString();
        _progressController.add(task!);
      }
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        await client.close();
      } catch (_) {}
    }
  }

  /// 初始化接收任务的保存路径和文件写入器
  Future<_ReceiveInitResult?> _initReceiveTask({
    required String fileName,
    required int fileSize,
    required String taskId,
    required String senderIp,
  }) async {
    try {
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

      final task = FileTransferTask(
        id: taskId,
        fileName: fileName,
        filePath: savePath,
        fileSize: fileSize,
        targetIp: senderIp,
        port: defaultPort,
        isSender: false,
        status: TransferStatus.transferring,
      );

      _activeTasks[taskId] = task;
      _newTaskController.add(task);
      _progressController.add(task);

      final saveFile = File(savePath);
      final sink = saveFile.openWrite();

      debugPrint('开始接收文件: $fileName (${_formatFileSize(fileSize)})');

      return _ReceiveInitResult(
        task: task,
        savePath: savePath,
        sink: sink,
      );
    } catch (e) {
      debugPrint('初始化接收任务失败: $e');
      return null;
    }
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
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
      String? downloadsPath;
      try {
        final dir = await getDownloadsDirectory();
        downloadsPath = dir?.path;
      } catch (_) {}
      if (downloadsPath != null && downloadsPath.isNotEmpty) {
        return '$downloadsPath\\WeChatLanTransfer';
      }
      // 回退：使用 USERPROFILE 环境变量
      final userProfile = Platform.environment['USERPROFILE'] ?? '.';
      return '$userProfile\\Downloads\\WeChatLanTransfer';
    } else if (Platform.isMacOS) {
      // macOS: 使用 Downloads 目录
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
      // Linux: 使用 Downloads 目录
      String? downloadsPath;
      try {
        final dir = await getDownloadsDirectory();
        downloadsPath = dir?.path;
      } catch (_) {}
      if (downloadsPath != null && downloadsPath.isNotEmpty) {
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
