// LocalSend Protocol v2 DTO（全对齐官方 packages/core/src/http/dto_v2.rs）。
// JSON 字段 camelCase；可空字段缺省省略（对齐 serde skip_serializing_if）。
// 纯数据 + 手写编解码，可单测。

import 'package:mime/mime.dart';

/// v2 协议版本字符串（官方 PROTOCOL_VERSION_V2）。
const String kLsProtocolVersion = '2.2';

/// v2 标准 HTTP/UDP 端口。
const int kLsDefaultPort = 53317;

/// v2 组播地址（发现）。
const String kLsMulticastAddr = '224.0.0.167';

/// 设备信息 DTO（register/prepare-upload info 字段/info 响应共用）。
class LsDeviceDto {
  final String alias;
  final String version;
  final String? deviceModel;
  final String? deviceType;
  final String fingerprint;
  final int port;
  final String protocol; // 本项目恒为 https
  final bool download;

  const LsDeviceDto({
    required this.alias,
    required this.fingerprint,
    required this.port,
    this.version = kLsProtocolVersion,
    this.deviceModel,
    this.deviceType,
    this.protocol = 'https',
    this.download = false,
  });

  Map<String, dynamic> toJson() => {
        'alias': alias,
        'version': version,
        if (deviceModel != null) 'deviceModel': deviceModel,
        if (deviceType != null) 'deviceType': deviceType,
        'fingerprint': fingerprint,
        'port': port,
        'protocol': protocol,
        'download': download,
      };

  factory LsDeviceDto.fromJson(Map<String, dynamic> json) => LsDeviceDto(
        alias: '${json['alias'] ?? ''}',
        version: '${json['version'] ?? kLsProtocolVersion}',
        deviceModel: json['deviceModel'] as String?,
        deviceType: json['deviceType'] as String?,
        fingerprint: '${json['fingerprint'] ?? ''}',
        port: (json['port'] as num?)?.toInt() ?? kLsDefaultPort,
        protocol: '${json['protocol'] ?? 'https'}',
        download: json['download'] == true,
      );
}

/// 文件元数据 DTO（对齐官方 FileDto）。
class LsFileDto {
  final String id;
  final String fileName;
  final int size;
  final String fileType;
  final String? sha256;
  final String? preview;
  final Map<String, String>? metadata; // modified / accessed（RFC3339）

  const LsFileDto({
    required this.id,
    required this.fileName,
    required this.size,
    required this.fileType,
    this.sha256,
    this.preview,
    this.metadata,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'fileName': fileName,
        'size': size,
        'fileType': fileType,
        if (sha256 != null && sha256!.isNotEmpty) 'sha256': sha256,
        if (preview != null) 'preview': preview,
        if (metadata != null && metadata!.isNotEmpty) 'metadata': metadata,
      };

  factory LsFileDto.fromJson(Map<String, dynamic> json) => LsFileDto(
        id: '${json['id'] ?? ''}',
        fileName: '${json['fileName'] ?? ''}',
        size: (json['size'] as num?)?.toInt() ?? 0,
        fileType: '${json['fileType'] ?? 'application/octet-stream'}',
        sha256: json['sha256'] as String?,
        preview: json['preview'] as String?,
        metadata: (json['metadata'] as Map?)?.cast<String, String>(),
      );

  /// 从本地路径构造（fileType 按扩展名推断）。
  factory LsFileDto.fromPath({
    required String id,
    required String filePath,
    required int size,
    String? fileName,
    String? sha256,
  }) {
    final name = fileName ?? filePath.split('/').last.split('\\').last;
    return LsFileDto(
      id: id,
      fileName: name,
      size: size,
      fileType: lookupMimeType(name) ?? 'application/octet-stream',
      sha256: sha256,
    );
  }
}

/// POST /prepare-upload 请求体。
class LsPrepareUploadRequest {
  final LsDeviceDto info;
  final Map<String, LsFileDto> files;

  const LsPrepareUploadRequest({required this.info, required this.files});

  Map<String, dynamic> toJson() => {
        'info': info.toJson(),
        'files': files.map((k, v) => MapEntry(k, v.toJson())),
      };
}

/// POST /prepare-upload 成功响应体。
class LsPrepareUploadResponse {
  final String sessionId;
  final Map<String, String> files; // fileId -> token

  const LsPrepareUploadResponse({required this.sessionId, required this.files});

  factory LsPrepareUploadResponse.fromJson(Map<String, dynamic> json) =>
      LsPrepareUploadResponse(
        sessionId: '${json['sessionId'] ?? ''}',
        files: (json['files'] as Map?)?.cast<String, String>() ?? const {},
      );
}

/// prepare-upload 失败的类型化错误（官方状态码语义）。
enum LsErrorKind {
  pinRequired, // 401：缺 PIN 或 PIN 错
  rejected, // 403：用户拒绝 / 发送方取消
  busy, // 409：对端正被其他会话占用
  tooManyRequests, // 429：PIN 尝试超限
  checksumMismatch, // 422：哈希不匹配
  unknown, // 其他
}

class LsSendError implements Exception {
  final LsErrorKind kind;
  final int statusCode;
  final String message;
  const LsSendError(this.kind, this.statusCode, this.message);

  @override
  String toString() => 'LsSendError($kind, $statusCode, $message)';

  /// 按状态码归类（官方 client/v2.rs 错误注释）。
  static LsSendError fromStatus(int status, String body) {
    final kind = switch (status) {
      401 => LsErrorKind.pinRequired,
      403 => LsErrorKind.rejected,
      409 => LsErrorKind.busy,
      422 => LsErrorKind.checksumMismatch,
      429 => LsErrorKind.tooManyRequests,
      _ => LsErrorKind.unknown,
    };
    return LsSendError(kind, status, body);
  }

  /// 人类可读文案（发送气泡失败原因）。
  String get userText => switch (kind) {
        LsErrorKind.pinRequired => '对方需要接收 PIN',
        LsErrorKind.rejected => '对方拒绝了本次传输',
        LsErrorKind.busy => '对方正在处理其他传输',
        LsErrorKind.tooManyRequests => 'PIN 错误次数过多，请稍后再试',
        LsErrorKind.checksumMismatch => '校验失败，对方已拒绝文件',
        LsErrorKind.unknown => message.isEmpty ? '传输失败' : message,
      };
}

/// 按文件名推断 MIME（v2 FileDto.fileType 必填）。
String lsGuessMime(String fileName) =>
    lookupMimeType(fileName) ?? 'application/octet-stream';
