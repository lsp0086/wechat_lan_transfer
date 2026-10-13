// E1：设备图标纯函数。从 ChatListPage._buildDeviceItem 抽出，可单测。
// 返回图标/底色/前景色三元组；Widget 组装留宿主。

/// 设备图标三元组。
({String icon, bool onlineBg, bool onlineFg}) deviceIconMeta({
  required String type,
  required bool isOnline,
}) =>
    (icon: type, onlineBg: isOnline, onlineFg: isOnline);

/// 是否手机图标。
bool usePhoneIcon(String type) => type == 'mobile';

/// PIN 保存文案。
String pinSavedText(String pin) =>
    pin.isEmpty ? '接收 PIN 已关闭' : '接收 PIN 已启用';

/// 指纹小写回退（非指纹键返回 null）。
String? peerFingerprintOrNull(String deviceKey, bool isFingerprintKey) =>
    isFingerprintKey ? deviceKey.toLowerCase() : null;
