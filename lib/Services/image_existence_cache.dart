// E1：图片缓存复用。从 ChatPage._buildImageBubble 残留三段内联缓存读写抽出的
// 可单测小容器。图片尺寸（Size.zero 表解码失败）+ 文件存在性共用一套裁剪语义。

import 'dart:ui' show Size;

import 'transfer_limits.dart';

/// 图片尺寸/存在性缓存：命中返回，未命中由调用方 IO 回填。
class ImageExistenceCache {
  ImageExistenceCache({this.capacity = kMaxCacheEntries});

  final int capacity;
  final Map<String, Size?> sizes = {};
  final Map<String, bool> exists = {};

  bool? lookupExists(String? path) =>
      path == null ? null : exists[path];

  void storeExists(String path, bool value) {
    exists[path] = value;
    _trim(exists);
  }

  // E1：存在性薄委托收敛（先查缓存，未命中则探测并回填）。
  bool lookupOrProbeExists(String? path, bool Function(String p) existsSync) {
    final cached = lookupExists(path);
    if (cached != null) return cached;
    final probed = path != null && existsSync(path);
    if (path != null) storeExists(path, probed);
    return probed;
  }

  /// Size.zero 表解码失败（调用方转为 null）。
  Size? lookupSize(String? path) => path == null ? null : sizes[path];

  void storeSize(String path, Size? size) {
    sizes[path] = size;
    _trim(sizes);
  }

  void _trim<V>(Map<String, V> cache) {
    if (cache.length <= capacity) return;
    final drop = cache.keys.take(cache.length ~/ 2).toList();
    for (final k in drop) {
      cache.remove(k);
    }
  }

  void clear() {
    sizes.clear();
    exists.clear();
  }
}
