// E1：发送分发/面板状态纯逻辑。从 ChatPage._trySend/onTapMore/onTapEmoji
// 与滚动/面板残留抽出，可单测。IO/动画/setState 留宿主。

import 'package:wechat_lan_transfer/Model/chat_model.dart' show MessageType;

/// 统一发送消息的动作类型（E1：从 ChatPage 上移至此，避免循环依赖）。
enum SendActionType { text, file, image, audio, audioRetry }

/// 失败重发类型映射：图片走 image，其余走 file（纯枚举映射可单测）。
SendActionType resolveRetrySendType(MessageType msgType) =>
    msgType == MessageType.image ? SendActionType.image : SendActionType.file;

/// 发送动作分发键（_trySend switch 收敛，调用方据键走具体发送）。
String sendDispatchKey({
  required String type,
  required bool isImageFlag,
}) {
  switch (type) {
    case 'text':
      return 'text';
    case 'file':
      return 'file';
    case 'image':
      return 'image';
    case 'audio':
      return 'audio';
    case 'audioRetry':
      return 'audioRetry';
    default:
      return isImageFlag ? 'image' : 'file';
  }
}

/// 文件发送图片判定（file/image 共用分支，image 类型强制图片）。
bool resolveSendIsImage({required String type, required bool isImageFlag}) =>
    isImageFlag || type == 'image';

/// 面板切换状态机（more/emoji 二选一，voice 关闭；返回下一态）。
({bool isMore, bool emojiState, bool needFocus, bool needUnfocus})
    nextMorePanel({required bool isMore, required bool hasFocus}) {
  if (isMore) return (isMore: false, emojiState: false, needFocus: true, needUnfocus: false);
  return (
    isMore: true,
    emojiState: false,
    needFocus: false,
    needUnfocus: hasFocus,
  );
}

/// emoji 面板切换状态机（与 more 互斥）。
({bool isMore, bool emojiState, bool needFocus, bool needUnfocus})
    nextEmojiPanel({required bool emojiState, required bool hasFocus}) {
  if (emojiState) {
    return (isMore: false, emojiState: false, needFocus: true, needUnfocus: false);
  }
  return (
    isMore: false,
    emojiState: true,
    needFocus: false,
    needUnfocus: hasFocus,
  );
}

/// 面板切换防抖时长。
const int kPanelSwitchMs = 300;

/// 滚动动画时长。
const int kScrollAnimMs = 200;

/// 面板高度占比（Scaffold body 40%）。
const double kPanelHeightRatio = 0.4;

// E1：面板高度（可用高度按占比折算，防键盘/面板溢出）。
double panelHeight(double maxH, {double ratio = kPanelHeightRatio}) =>
    maxH * ratio;

/// 历史触发阈值（顶部 40px 内补一页）。
const double kHistoryTriggerPx = 40;

/// 是否触发历史加载（滚动到顶部附近且还有更多）。
bool shouldLoadOlder({required double pixels, required bool hasMore}) =>
    pixels <= kHistoryTriggerPx && hasMore;

/// 输入栏图标：语音模式显示键盘，否则显示麦克风（纯判定可单测）。
bool useKeyboardIcon({required bool isVoice}) => isVoice;

/// 更多/表情面板图标：展开显示键盘，否则显示原图标（纯判定可单测）。
bool useKeyboardForPanel({required bool expanded}) => expanded;

/// 发送按钮可见：输入非空才显示圆形发送，否则显示更多按钮。
bool shouldShowSendButton({required String text}) => text.isNotEmpty;
