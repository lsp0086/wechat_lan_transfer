// E1：有界内存缓存。从 ChatPage 抽出的纯容器，可单测。
// 图片尺寸/文件存在性缓存共用：超上限删一半（FIFO 近似），防无限制增长。

import 'transfer_limits.dart';

/// 有界缓存：put 超上限时删最旧一半；命中 get 返回 value。
class BoundedCache<V> {
  BoundedCache({this.capacity = kMaxCacheEntries});

  final int capacity;
  final Map<String, V> entries = {};

  void put(String key, V value) {
    entries[key] = value;
    trimIfNeeded();
  }

  V? get(String key) => entries[key];

  /// 超上限删最旧一半（Map 按插入序，取前半 keys）。
  void trimIfNeeded() {
    if (entries.length <= capacity) return;
    final keysToRemove = entries.keys.take(entries.length ~/ 2).toList();
    for (final key in keysToRemove) {
      entries.remove(key);
    }
  }
}

/// Map 版原地裁剪（存量调用点兼容，无需改类型时用）。
void trimMapCache<V>(Map<String, V> cache, {int capacity = kMaxCacheEntries}) {
  if (cache.length <= capacity) return;
  final keysToRemove = cache.keys.take(cache.length ~/ 2).toList();
  for (final key in keysToRemove) {
    cache.remove(key);
  }
}
