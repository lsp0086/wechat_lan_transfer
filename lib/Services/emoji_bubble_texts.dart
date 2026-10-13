// E1：emoji 列表与气泡文案纯函数。从 ChatPage._buildEmojiList 与
// 气泡/解压/录音硬编码中文残留抽出，可单测。UI 组装留宿主。

/// emoji 码点是否应保留（跳过未分配/装饰区间）。
bool keepEmojiCodePoint(int cp) {
  if (cp >= 0x1F4D0 && cp <= 0x1F4FF) return false;
  if (cp >= 0x1F550 && cp <= 0x1F5FF) return false;
  if (cp >= 0x1F650 && cp <= 0x1F67F) return false;
  if (cp >= 0x1F6D5 && cp <= 0x1F6FF) return false;
  if (cp >= 0x1F780 && cp <= 0x1F7FF) return false;
  if (cp >= 0x1F800 && cp <= 0x1F8FF) return false;
  if (cp >= 0x1FA00 && cp <= 0x1FA6F) return false;
  if (cp >= 0x1FA70 && cp <= 0x1FAFF) return false;
  return true;
}

/// 按码点列表过滤出可渲染 emoji。
List<String> filterEmojiCodePoints(List<String> all) => [
      for (final ch in all)
        if (ch.runes.isNotEmpty && keepEmojiCodePoint(ch.runes.first)) ch,
    ];

/// 构建精选常用 emoji（与原 _buildEmojiList 同分布，可单测分布/过滤）。
List<String> buildEmojiList() {
  final smileys = List.generate(80, (i) => String.fromCharCode(0x1F600 + i));
  final misc = List.generate(768, (i) => String.fromCharCode(0x1F300 + i));
  final transport = List.generate(128, (i) => String.fromCharCode(0x1F680 + i));
  final supplement =
      List.generate(256, (i) => String.fromCharCode(0x1F900 + i));
  const gestures = [
    '\u{1F44D}',
    '\u{1F44E}',
    '\u{1F44F}',
    '\u{1F44A}',
    '\u{270A}',
    '\u{270B}',
    '\u{270C}',
    '\u{1F44C}',
    '\u{1F450}',
    '\u{1F932}',
  ];
  return filterEmojiCodePoints(
      [...smileys, ...misc, ...transport, ...supplement, ...gestures]);
}

/// 离页确认对话框三文案（标题/正文/取消/确认共四项）。
({String title, String content, String stay, String leave})
    leaveConfirmTexts() => (
          title: '传输进行中',
          content: '有消息正在传输，现在离开可能导致传输中断。确定离开吗？',
          stay: '继续等待',
          leave: '仍要离开',
        );

/// 图片气泡失败文案（发送/接收区分）。
String imageFailText({required bool isMe}) => isMe ? '发送失败' : '接收失败';

/// 重试/续收按钮文案。
String imageRetryText() => '点击重试';
String imageResumeText() => '点击继续接收';

/// 缺图占位文案三处收敛（气泡/查看器/异常）。
String missingImageText() => '图片已删除';
String imageViewerMissingText() => '图片已删除或不可用';

/// 解压结果文案。
String extractAbortedContent(String zipFileName) =>
    '📁 解压中止（过大）: $zipFileName';
String extractDoneContent(String folderName) => '📁 $folderName';
String extractCountText(int count) => '$count 个项目';

/// 录音遮罩/按钮文案三处收敛。
String recordCancelHint({required bool cancelling}) =>
    cancelling ? '松开 取消' : '上滑取消';
String recordSendHint() => '松开发送';
String recordReleaseHint({required bool cancelling}) =>
    cancelling ? '松开 取消' : '松开 发送';
String recordHoldHint() => '按住 说话';

/// 录音权限/启动失败 toast。
String recordPermText() => '请授予麦克风权限以录制语音消息';
String recordStartFailText() => '录音启动失败，请重试';

/// 文件选择对话框标题。
String folderPickTitle() => '选择要发送的文件夹';

/// 图片预览标题回退。
String imageViewerTitle({String? fileName}) => fileName ?? '图片';

/// PIN 对话框/pending 按钮文案收敛。
String cancelText() => '取消';
String pinRetryText() => '重试';
String pendingAcceptText() => '接收';
String pendingRejectText() => '拒绝';

/// 语音气泡恒定标签（8 处内联字面收敛，发送/接收/中断/补元共用）。
String audioLabel() => '语音消息';
