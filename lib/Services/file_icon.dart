// E1：文件图标分类。从 ChatPage._getFileIcon 抽出的纯函数，可单测。
// 返回图标名（调用方再映射为 IconData，避免 services 依赖 flutter/material）。
// folder 优先；扩展名小写匹配；无扩展名/未知走 file。

/// 文件图标分类名：folder/pdf/doc/sheet/slide/image/video/audio/archive/apk/text/file。
String fileIconName(String fileName, {bool isFolder = false}) {
  if (isFolder) return 'folder';
  final dot = fileName.lastIndexOf('.');
  if (dot < 0 || dot == fileName.length - 1) return 'file';
  switch (fileName.substring(dot + 1).toLowerCase()) {
    case 'pdf':
      return 'pdf';
    case 'doc':
    case 'docx':
      return 'doc';
    case 'xls':
    case 'xlsx':
      return 'sheet';
    case 'ppt':
    case 'pptx':
      return 'slide';
    case 'jpg':
    case 'jpeg':
    case 'png':
    case 'gif':
    case 'bmp':
    case 'webp':
    case 'heic':
    case 'heif':
    case 'svg':
    case 'tiff':
    case 'ico':
      return 'image';
    case 'mp4':
    case 'avi':
    case 'mov':
    case 'mkv':
      return 'video';
    case 'mp3':
    case 'wav':
    case 'flac':
    case 'aac':
      return 'audio';
    case 'zip':
    case 'rar':
    case '7z':
    case 'tar':
    case 'gz':
      return 'archive';
    case 'apk':
      return 'apk';
    case 'txt':
      return 'text';
    default:
      return 'file';
  }
}
