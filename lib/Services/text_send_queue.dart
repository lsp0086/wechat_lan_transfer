// E1：文字发送队列。从 ChatPage 私有 _QueuedText + _textSendQueue/_textQueueRunning
// 抽出的可单测容器。P1-3 入队 + 串行消费 + 相邻间隔（kTextSendGapMs 由调用方延迟）。

/// P1-3：文字发送队列条目。
class QueuedText {
  final String msgId;
  final String text;
  final int retry;
  const QueuedText(this.msgId, this.text, this.retry);
}

/// 串行文字队列（FIFO；调用方负责 running 门控与间隔延迟）。
class TextSendQueue {
  final List<QueuedText> items = [];
  bool running = false;

  bool get isEmpty => items.isEmpty;
  int get length => items.length;

  void add(QueuedText item) => items.add(item);

  QueuedText? takeNext() => items.isEmpty ? null : items.removeAt(0);

  bool get needsGap => items.isNotEmpty;

  void clear() {
    items.clear();
    running = false;
  }
}
