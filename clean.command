#!/bin/bash
# 清理 Flutter / Android / iOS / macOS 编译缓存与垃圾
# 用法：
#   ./clean.command          安全清理（仅本项目产物，dist/ 保留）
#   ./clean.command --deep   追加清理 Gradle 全局缓存（所有项目共用，
#                            下次 Android 构建会重新下载 Gradle 发行包）
set -u
cd "$(dirname "$0")"
PROJ="$(pwd)"
DEEP=true
# [ "${1:-}" = "--deep" ] && DEEP=true

FREED=0
rm_size() {
  local target="$1"
  [ -e "$target" ] || return 0
  local kb
  kb=$(du -sk "$target" 2>/dev/null | awk '{print $1}')
  FREED=$((FREED + ${kb:-0}))
  rm -rf "$target"
  echo "    已删: ${target#$PROJ/}"
}

echo "==> flutter clean"
flutter clean

echo "==> 项目内构建残留"
rm_size "$PROJ/build"
rm_size "$PROJ/android/.gradle"
rm_size "$PROJ/.dart_tool"
rm_size "$PROJ/.flutter-plugins"
rm_size "$PROJ/.flutter-plugins-dependencies"
rm_size "$PROJ/ios/Flutter/ephemeral"
rm_size "$PROJ/macos/Flutter/ephemeral"

echo "==> CocoaPods 产物（pod install 自动重建）"
rm_size "$PROJ/ios/Pods"
rm_size "$PROJ/ios/Podfile.lock"
rm_size "$PROJ/macos/Pods"
rm_size "$PROJ/macos/Podfile.lock"

echo "==> 本项目 Xcode DerivedData（之前 build.db 损坏就出在这里）"
rm_size "$HOME/Library/Developer/Xcode/DerivedData/wechat_lan_transfer-"

if $DEEP; then
  echo "==> [--deep] Gradle 全局缓存（含 wrapper 发行包，影响所有项目）"
  rm_size "$HOME/.gradle/caches"
  rm_size "$HOME/.gradle/wrapper/dists"
fi

echo "==> 完成，共释放 $((FREED / 1024)) MB"
echo "    dist/ 交付物已保留；下次构建全量重建。"
