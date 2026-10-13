// E1：应用时钟薄封装。从 ChatPage/ChatList 约25处 DateTime.now() 抽出，可单测。
// 默认直调 DateTime.now()（不动行为），fixed 参数仅供单测注入。

/// 当前毫秒时间戳（默认 DateTime.now().millisecondsSinceEpoch）。
int nowMs({int? fixed}) => fixed ?? DateTime.now().millisecondsSinceEpoch;

/// 当前时间（默认 DateTime.now()）。
DateTime now({DateTime? fixed}) => fixed ?? DateTime.now();

/// 当前微秒时间戳（默认 DateTime.now().microsecondsSinceEpoch）。
int nowUs({int? fixed}) => fixed ?? DateTime.now().microsecondsSinceEpoch;
