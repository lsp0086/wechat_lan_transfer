// E1：图片后缀判断。从 ChatListPage/ChatPage 抽出的纯函数，可单测。
// 统一两处曾不一致的后缀表（含 heic/heif/svg）。
// 新库 mime：先按扩展名查 MIME（image/* 即图片），未知后缀回退硬编码表
// （防 mime 库未覆盖 heic/heif 等小众后缀时漏判）。

import 'package:mime/mime.dart';

/// 文件名是否为图片（按扩展名，大小写不敏感；无扩展名返回 false）。
bool isImageFileName(String fileName) {
  // 新库 mime 优先：image/* 即图片。
  final mimeType = lookupMimeType(fileName);
  if (mimeType != null && mimeType.startsWith('image/')) return true;
  // 回退硬编码表（含 mime 未覆盖的 heic/heif/svg 等）。
  final dot = fileName.lastIndexOf('.');
  if (dot < 0 || dot == fileName.length - 1) return false;
  switch (fileName.substring(dot + 1).toLowerCase()) {
    case 'jpg':
    case 'jpeg':
    case 'png':
    case 'gif':
    case 'bmp':
    case 'webp':
    case 'heic':
    case 'heif':
    case 'svg':
      return true;
    default:
      return false;
  }
}
