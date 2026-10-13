// E1：聊天默认值。从 ChatListPage/ChatPage 残留字面抽出，可单测。
// 初始化占位与默认配置集中收敛；IO/持久化留宿主。

/// 未知 IP 占位（发现未就绪/网卡缺失时）。
const String kUnknownIp = '未知IP';

/// 设备名加载中占位。
const String kLoadingDeviceName = '加载中...';

/// 默认存储标签（不落盘，落盘时转空串）。
const String kDefaultStorageLabel = '默认文件夹';

/// 默认发现可见性三档（all/paired/stealth）。
const String kDefaultVisibility = 'all';

/// 是否未知 IP。
bool isUnknownIp(String ip) => ip == kUnknownIp;

/// 是否默认存储标签。
bool isDefaultStorageTag(String label) => label == kDefaultStorageLabel;
