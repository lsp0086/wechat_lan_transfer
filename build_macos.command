#!/bin/bash
set -e
cd "$(dirname "$0")"

APP_NAME="wechat_lan_transfer"
SRC_APP="build/macos/Build/Products/Release/${APP_NAME}.app"
DIST_DIR="dist"

echo "==> flutter build macos --release"
flutter build macos --release
BUILD_STATUS=$?
if [ $BUILD_STATUS -ne 0 ]; then
  echo "构建失败（flutter build macos 退出码 $BUILD_STATUS）"
  exit $BUILD_STATUS
fi

if [ ! -d "$SRC_APP" ]; then
  echo "构建失败：找不到 $SRC_APP"
  exit 1
fi

echo "==> 输出到 $DIST_DIR/"
mkdir -p "$DIST_DIR"
rm -rf "$DIST_DIR/${APP_NAME}.app"
cp -R "$SRC_APP" "$DIST_DIR/"

echo "==> flutter clean（清掉 .dart_tool 构建标记，防止下次增量重建缺 native_assets 框架）"
flutter clean

echo "==> 完成：$DIST_DIR/${APP_NAME}.app"
open "$DIST_DIR" 2>/dev/null || true
