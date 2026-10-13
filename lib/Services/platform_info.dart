// E1：平台判定纯函数。从 ChatListPage._isDesktopPlatform 与
// ChatPage._isImageCompressSupported/广播 deviceType 残留抽出，可单测。

/// 是否桌面平台（Windows/macOS/Linux）。
bool isDesktopPlatform({
  required bool isWindows,
  required bool isMacOS,
  required bool isLinux,
}) =>
    isWindows || isMacOS || isLinux;

/// 设备类型标签：mobile/desktop（广播与回包共用）。
String deviceTypeLabel({required bool isMobile}) =>
    isMobile ? 'mobile' : 'desktop';

/// 键盘是否弹起（viewInsets.bottom > 0）。
bool isKeyboardVisible(double bottomInset) => bottomInset > 0;
