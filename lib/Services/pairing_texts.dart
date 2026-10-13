// E1：配对对话框纯文案。从 Chat/pairing_dialog.dart 抽出，可单测。
// 弹窗挂载留宿主。

/// 安全截短指纹：不足 16 位原样返回，避免 RangeError。
String shortFingerprint(String deviceKey, {int len = 16}) =>
    deviceKey.length <= len ? deviceKey : deviceKey.substring(0, len);

/// 标题/动作文案。
String pairingTitle() => '发现新设备';

/// P1-10：手动配对（设备卡片长按）标题。
String pairingManualTitle() => '设备配对';
String pairingRequestLine(String name) => '$name 请求配对，请核对指纹：';
String pairingShortLine(String shortFp) => '前16位: $shortFp…';
String pairingFullTitle() => '查看完整指纹';
String pairingBlockText() => '拉黑';
String pairingTrustText() => '信任并配对';

/// P1-10：长按配对时的状态提示。
String pairingAlreadyText(String name) => '$name 已配对，无需重复操作';
String pairingBlockedHintText(String name) => '$name 已被拉黑，请先在设置中解除';

// E1：配对信任结果判定收敛（true 即信任）。
bool isTrustedResult(bool? v) => v == true;

// E1：配对拒绝结果判定收敛（false 即拉黑）。
bool isRejectedResult(bool? v) => v == false;
