#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "==> flutter build apk --release"
flutter build apk --release
BUILD_STATUS=$?
if [ $BUILD_STATUS -ne 0 ]; then
  echo "构建失败（flutter build apk 退出码 $BUILD_STATUS）"
  exit $BUILD_STATUS
fi

APK="build/app/outputs/flutter-apk/app-release.apk"
if [ ! -f "$APK" ]; then
  echo "构建失败：找不到 $APK"
  exit 1
fi

echo "==> 输出 APK"
DIST_DIR="dist"
mkdir -p "$DIST_DIR"
cp "$APK" "$DIST_DIR/app-release.apk"

echo "==> flutter clean（清掉 .dart_tool 构建标记，防止下次增量重建缺 native_assets 框架）"
flutter clean

echo "==> 完成：$DIST_DIR/app-release.apk"
open "$DIST_DIR" 2>/dev/null || true
