#!/bin/bash
set -e
cd "$(dirname "$0")"

DIST_DIR="dist"
mkdir -p "$DIST_DIR"

echo "==> flutter build ios --release"
flutter build ios --release
BUILD_STATUS=$?
if [ $BUILD_STATUS -ne 0 ]; then
  echo "构建失败（flutter build ios 退出码 $BUILD_STATUS）"
  exit $BUILD_STATUS
fi

SRC_APP="build/ios/iphoneos/wechat_lan_transfer.app"
SRC_IPA="build/ios/iphoneos/wechat_lan_transfer.ipa"

if [ -f "$SRC_IPA" ]; then
  echo "==> 输出 wechat_lan_transfer.ipa 到 $DIST_DIR/"
  cp "$SRC_IPA" "$DIST_DIR/wechat_lan_transfer.ipa"
elif [ -d "$SRC_APP" ]; then
  echo "==> 输出 wechat_lan_transfer.app 到 $DIST_DIR/"
  rm -rf "$DIST_DIR/wechat_lan_transfer.app"
  cp -R "$SRC_APP" "$DIST_DIR/wechat_lan_transfer.app"
fi

# 如果连接了真机设备，尝试自动安装到设备（通过 devicectl，需 iOS 17+）
echo "==> 检查并尝试安装到已连接的 iOS 设备..."
DEVICE_ID="$(xcrun devicectl list devices 2>/dev/null | awk '/\(UDID\)/ && /connected/ {for (i=1; i<NF; i++) if ($(i+1) == "(UDID)") {print $i; exit}}')"
if [ -z "$DEVICE_ID" ]; then
  echo "（未检测到已连接的 iOS 设备，跳过自动安装）"
elif [ ! -d "$DIST_DIR/wechat_lan_transfer.app" ]; then
  echo "（未找到 $DIST_DIR/wechat_lan_transfer.app，跳过自动安装）"
else
  echo "==> 安装到设备 $DEVICE_ID ..."
  if xcrun devicectl device install app --device "$DEVICE_ID" "$DIST_DIR/wechat_lan_transfer.app"; then
    echo "==> 安装成功！首次打开若提示不受信任：设置 → 通用 → VPN与设备管理 → 信任开发者"
  else
    echo "（安装失败：请解锁 iPhone 并信任此电脑后重试，或用 Xcode 直接运行）"
  fi
fi

echo "==> 删除 build 文件夹"
rm -rf build

echo "==> 完成！"
open "$DIST_DIR" 2>/dev/null || true
