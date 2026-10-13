// E1：设备详情页纯文案。从 Chat/chat_info_page.dart 抽出，可单测。
// 缓存清除/导航留宿主。

/// 标题。
String infoTitle() => '设备详情';

/// IP 行。
String infoIpLine(String id) => '局域网IP: $id';

/// 三行设置项。
String infoTopLabel() => '置顶该设备';
String infoBlockLabel() => '加入传输黑名单';
String infoAutoRecvLabel() => '自动接收文件';

/// 清除行/确认框。
String infoClearLabel() => '清除聊天记录';
String infoClearTitle() => '清除聊天记录';
String infoClearContent(String name) =>
    '确定要清除与 $name 的所有聊天记录吗？\n\n此操作不会删除设备记录，仅清空聊天消息。';
String infoCancelText() => '取消';
String infoConfirmClearText() => '确定清除';

/// 结果提示。
String infoClearedText(String name) => '已清除与 $name 的聊天记录';
String infoClearFailText(Object e) => '清除失败: $e';
