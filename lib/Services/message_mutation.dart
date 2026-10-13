// E1：消息列表变异纯函数。setState 内联 add/insertAll 收敛，可单测。
// 宿主只留 setState 赋值，不直接变异原列表；IO/缓存留宿主。

/// E1：追加一条（chatData.add 收敛，返回新 List）。
List<T> appendMessage<T>(List<T> list, T msg) => [...list, msg];

/// E1：历史前插一批（chatData.insertAll(0, page) 收敛，返回新 List）。
List<T> prependHistory<T>(List<T> list, List<T> page) => [...page, ...list];

/// E1：按下标替换一条（chatData[i] = markXxx 收敛的列表版，返回新 List）。
List<T> replaceAt<T>(List<T> list, int index, T msg) {
  if (index < 0 || index >= list.length) return list;
  final next = List<T>.from(list);
  next[index] = msg;
  return next;
}

/// E1：按 id 移除（返回新 List，原列表不动）。
List<T> removeById<T>(List<T> list, String Function(T) idOf, String id) =>
    list.where((m) => idOf(m) != id).toList();
