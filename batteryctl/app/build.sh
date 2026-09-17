#!/bin/bash
#
# 构建 BatteryCtl.app
#
# 只需要 Xcode Command Line Tools（含 swiftc），不需要完整 Xcode，
# 也不需要任何第三方打包工具。
#
# 用法:
#   bash build.sh           # 构建
#   bash build.sh clean     # 清理产物
#
set -euo pipefail

APP_NAME="BatteryCtl"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_TOOL_DIR="$(cd "$HERE/.." && pwd)"          # tools/batteryctl
APP_DIR="$REPO_TOOL_DIR/$APP_NAME.app"
BUILD_DIR="$REPO_TOOL_DIR/.build"
SRC_DIR="$HERE/Sources"

# clang 模块缓存必须放在工作区内：默认位置在系统临时目录，
# 在某些受限环境下会因权限被拒。
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/module-cache"
export SWIFT_MODULECACHE_PATH="$CLANG_MODULE_CACHE_PATH"

if [ "${1:-build}" = "clean" ]; then
  rm -rf "$BUILD_DIR" "$APP_DIR"
  echo "已清理构建产物。"
  exit 0
fi

echo "==> 1/6 准备目录"
rm -rf "$BUILD_DIR" "$APP_DIR"
mkdir -p "$BUILD_DIR" "$CLANG_MODULE_CACHE_PATH"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

echo "==> 2/6 编译 Swift 源码"
SWIFT_SOURCES=()
while IFS= read -r f; do SWIFT_SOURCES+=("$f"); done < <(find "$SRC_DIR" -name '*.swift' | sort)
if [ ${#SWIFT_SOURCES[@]} -eq 0 ]; then
  echo "错误: $SRC_DIR 下没有 Swift 源文件。" >&2
  exit 1
fi
echo "    源文件: ${#SWIFT_SOURCES[@]} 个"

swiftc \
  -parse-as-library \
  -O \
  -target arm64-apple-macos13.0 \
  -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  -framework SwiftUI \
  -framework AppKit \
  -o "$APP_DIR/Contents/MacOS/$APP_NAME" \
  "${SWIFT_SOURCES[@]}"

echo "==> 3/6 拷贝 Python 核心（App 自包含）"
cp "$REPO_TOOL_DIR/batteryctl.py" "$APP_DIR/Contents/Resources/batteryctl.py"
mkdir -p "$APP_DIR/Contents/Resources/profiles"
cp "$REPO_TOOL_DIR"/profiles/*.json "$APP_DIR/Contents/Resources/profiles/"

echo "==> 4/6 写入 Info.plist"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>BatteryCtl</string>
  <key>CFBundleDisplayName</key><string>BatteryCtl</string>
  <key>CFBundleIdentifier</key><string>local.batteryctl.app</string>
  <key>CFBundleExecutable</key><string>BatteryCtl</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>本地自用，未签名</string>
</dict>
</plist>
PLIST

echo "==> 5/6 生成图标"
if swiftc -O -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
     -o "$BUILD_DIR/make_icon" "$HERE/make_icon.swift" 2>"$BUILD_DIR/icon.log" \
   && "$BUILD_DIR/make_icon" "$APP_DIR/Contents/Resources/AppIcon.icns" >>"$BUILD_DIR/icon.log" 2>&1; then
  echo "    图标已生成"
else
  echo "    警告: 图标生成失败，App 将使用默认图标（不影响功能）"
  sed 's/^/      /' "$BUILD_DIR/icon.log" | tail -6
fi

echo "==> 6/6 ad-hoc 签名"
if codesign --force --deep --sign - "$APP_DIR" 2>"$BUILD_DIR/codesign.log"; then
  echo "    已 ad-hoc 签名"
else
  echo "    警告: 签名失败，二进制仍可在本机运行"
  sed 's/^/      /' "$BUILD_DIR/codesign.log" | tail -3
fi

echo
echo "构建完成: $APP_DIR"
echo "启动: open \"$APP_DIR\""
