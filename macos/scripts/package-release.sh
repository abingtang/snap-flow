#!/usr/bin/env bash
# 本机构建 Release 安装包到 dist/（不提交 Git；上传到 GitHub Releases）。
# 用法：
#   ./scripts/package-release.sh
#   VERSION=0.0.1 ARCH=arm64 ./scripts/package-release.sh
#   SKIP_DMG=1 ./scripts/package-release.sh   # 只打 zip
#   SKIP_ZIP=1 ./scripts/package-release.sh   # 只打 dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SCHEME="${SCHEME:-SnapFlow}"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/build/SnapFlowReleaseDerivedData}"
ARCH="${ARCH:-arm64}"
# 默认同时产出 zip + 拖拽安装 DMG；设为 1 可跳过对应产物。
SKIP_ZIP="${SKIP_ZIP:-0}"
SKIP_DMG="${SKIP_DMG:-0}"

read_marketing_version() {
  # 从 project.pbxproj 读取第一处 MARKETING_VERSION
  local v
  v="$(grep -m1 'MARKETING_VERSION' "$ROOT/SnapFlow.xcodeproj/project.pbxproj" \
    | sed -E 's/.*MARKETING_VERSION = ([^;]+);/\1/' \
    | tr -d '[:space:]')"
  if [[ -z "${v:-}" ]]; then
    echo "无法从 project.pbxproj 读取 MARKETING_VERSION" >&2
    exit 1
  fi
  echo "$v"
}

VERSION="${VERSION:-$(read_marketing_version)}"
DIST_DIR="$ROOT/dist"
ZIP_NAME="SnapFlow-${VERSION}-${ARCH}.zip"
DMG_NAME="SnapFlow-${VERSION}-${ARCH}.dmg"
# 卷名不宜过长；Finder 窗口标题用此名称。
DMG_VOLUME_NAME="SnapFlow ${VERSION}"

DMG_BG_SCRIPT="$ROOT/scripts/generate-dmg-background.swift"
DMG_BG_DIR="$ROOT/scripts/dmg-resources"
DMG_BG_PNG="$DMG_BG_DIR/background.png"

ensure_dmg_background() {
  mkdir -p "$DMG_BG_DIR"
  if [[ -f "$DMG_BG_PNG" ]]; then
    return 0
  fi
  echo "==> Generating DMG background with install hint…"
  if [[ -f "$DMG_BG_SCRIPT" ]]; then
    /usr/bin/swift "$DMG_BG_SCRIPT" "$DMG_BG_PNG"
  else
    echo "缺少 $DMG_BG_SCRIPT，DMG 将无文字提示背景" >&2
  fi
}

# 生成「把 App 拖到 Applications」风格 DMG（带中文安装提示背景）。
# 优先 create-dmg（brew install create-dmg）；否则 hdiutil + AppleScript。
create_drag_to_applications_dmg() {
  local app_path="$1"
  local dmg_out="$2"
  local stage="$DIST_DIR/.dmg-stage"
  local tmp_dmg="$DIST_DIR/.tmp-SnapFlow-rw.dmg"
  local mount_root="/Volumes/${DMG_VOLUME_NAME}"
  local device=""
  local bg_arg=()

  ensure_dmg_background

  rm -rf "$stage"
  mkdir -p "$stage"
  ditto "$app_path" "$stage/SnapFlow.app"

  rm -f "$dmg_out" "$tmp_dmg"

  if command -v create-dmg >/dev/null 2>&1; then
    echo "==> Creating DMG with create-dmg（含安装提示背景）…"
    if [[ -f "$DMG_BG_PNG" ]]; then
      bg_arg=(--background "$DMG_BG_PNG")
    fi
    # --app-drop-link 自动添加 /Applications 快捷方式并摆位
    create-dmg \
      --volname "$DMG_VOLUME_NAME" \
      --window-pos 200 120 \
      --window-size 640 400 \
      --icon-size 100 \
      --icon "SnapFlow.app" 160 190 \
      --hide-extension "SnapFlow.app" \
      --app-drop-link 460 190 \
      "${bg_arg[@]}" \
      --no-internet-enable \
      "$dmg_out" \
      "$stage"
    rm -rf "$stage"
    return 0
  fi

  echo "==> Creating DMG with hdiutil（含安装提示背景）…"
  echo "    提示：brew install create-dmg 可获得更稳定的图标布局"
  ln -sf /Applications "$stage/Applications"
  if [[ -f "$DMG_BG_PNG" ]]; then
    mkdir -p "$stage/.background"
    # 隐藏背景目录，用户几乎看不到
    cp "$DMG_BG_PNG" "$stage/.background/background.png"
  fi

  # 若同名卷已挂载，先卸下避免冲突
  if [[ -d "$mount_root" ]]; then
    hdiutil detach "$mount_root" -force >/dev/null 2>&1 || true
  fi

  hdiutil create \
    -srcfolder "$stage" \
    -volname "$DMG_VOLUME_NAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -ov \
    "$tmp_dmg" >/dev/null

  # attach 输出含设备节点，例如 /dev/disk4
  device="$(hdiutil attach -readwrite -noverify -noautoopen "$tmp_dmg" \
    | awk '/^\/dev\// { print $1; exit }')"
  if [[ -z "$device" || ! -d "$mount_root" ]]; then
    echo "挂载临时 DMG 失败" >&2
    rm -f "$tmp_dmg"
    rm -rf "$stage"
    exit 1
  fi

  # Finder：图标布局 + 背景提示文案
  osascript <<EOF || true
tell application "Finder"
  tell disk "${DMG_VOLUME_NAME}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 520}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 100
    try
      set background picture of viewOptions to file ".background:background.png"
    end try
    set position of item "SnapFlow.app" of container window to {160, 190}
    set position of item "Applications" of container window to {460, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF

  # 尽量隐藏 .background（若存在）
  if [[ -d "$mount_root/.background" ]]; then
    SetFile -a V "$mount_root/.background" 2>/dev/null || true
  fi

  sync
  hdiutil detach "$device" -force >/dev/null
  # 再试一次按挂载点卸载
  if [[ -d "$mount_root" ]]; then
    hdiutil detach "$mount_root" -force >/dev/null 2>&1 || true
  fi

  hdiutil convert "$tmp_dmg" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    -o "$dmg_out" >/dev/null

  rm -f "$tmp_dmg"
  rm -rf "$stage"
}

echo "==> SnapFlow package-release"
echo "    version:  $VERSION"
echo "    arch:     $ARCH"
echo "    config:   $CONFIGURATION"
echo "    derived:  $DERIVED_DATA"
echo

# 确保发行包使用 icon-variants 源图，避免 Asset Catalog 残留旧图标
if [[ -x "$ROOT/scripts/sync-icons.sh" ]]; then
  "$ROOT/scripts/sync-icons.sh"
elif [[ -f "$ROOT/scripts/sync-icons.sh" ]]; then
  bash "$ROOT/scripts/sync-icons.sh"
fi

echo "==> Building…"
# 显式固定发行包设置，避免 Xcode 的有效配置重新启用覆盖率或调试变体。
xcodebuild \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -destination "platform=macOS,arch=${ARCH}" \
  ARCHS="$ARCH" \
  ONLY_ACTIVE_ARCH=YES \
  ENABLE_CODE_COVERAGE=NO \
  CLANG_COVERAGE_MAPPING=NO \
  ENABLE_DEBUG_DYLIB=NO \
  build

PRODUCTS_DIR="$DERIVED_DATA/Build/Products/$CONFIGURATION"
APP_SRC="$PRODUCTS_DIR/SnapFlow.app"
if [[ ! -d "$APP_SRC" ]]; then
  echo "未找到构建产物: $APP_SRC" >&2
  exit 1
fi

APP_BINARY="$APP_SRC/Contents/MacOS/SnapFlow"
if [[ ! -f "$APP_BINARY" ]]; then
  echo "未找到 App 可执行文件: $APP_BINARY" >&2
  exit 1
fi

ACTUAL_ARCHES="$(lipo -archs "$APP_BINARY")"
if [[ "$ACTUAL_ARCHES" != "$ARCH" ]]; then
  echo "发行包架构不符合预期: 期望 $ARCH，实际 $ACTUAL_ARCHES" >&2
  exit 1
fi

if otool -l "$APP_BINARY" | grep -Eq '__LLVM_COV|__llvm_prf_'; then
  echo "发行包仍包含覆盖率插桩段，已停止打包: $APP_BINARY" >&2
  exit 1
fi

echo "==> Staging into dist/"
mkdir -p "$DIST_DIR"
rm -rf "$DIST_DIR/SnapFlow.app"
# 使用 ditto 保留签名与资源
ditto "$APP_SRC" "$DIST_DIR/SnapFlow.app"

if [[ "$SKIP_ZIP" != "1" ]]; then
  echo "==> Zipping $ZIP_NAME"
  rm -f "$DIST_DIR/$ZIP_NAME"
  # --keepParent 使 zip 根目录为 SnapFlow.app
  ditto -c -k --keepParent "$DIST_DIR/SnapFlow.app" "$DIST_DIR/$ZIP_NAME"
fi

if [[ "$SKIP_DMG" != "1" ]]; then
  echo "==> Building drag-to-Applications DMG: $DMG_NAME"
  create_drag_to_applications_dmg "$DIST_DIR/SnapFlow.app" "$DIST_DIR/$DMG_NAME"
fi

echo
echo "==> Done"
echo "    App:  $DIST_DIR/SnapFlow.app"
if [[ "$SKIP_ZIP" != "1" ]]; then
  echo "    Zip:  $DIST_DIR/$ZIP_NAME"
  ls -lh "$DIST_DIR/$ZIP_NAME" || true
fi
if [[ "$SKIP_DMG" != "1" ]]; then
  echo "    DMG:  $DIST_DIR/$DMG_NAME"
  ls -lh "$DIST_DIR/$DMG_NAME" || true
fi
echo
echo "下一步（安装包不进 Git）："
echo "  1. git tag -a v${VERSION} -m \"SnapFlow ${VERSION}\""
echo "  2. git push origin v${VERSION}"
echo "  3. 在 GitHub Releases 创建 v${VERSION} 并上传："
if [[ "$SKIP_ZIP" != "1" ]]; then
  echo "       $DIST_DIR/$ZIP_NAME"
fi
if [[ "$SKIP_DMG" != "1" ]]; then
  echo "       $DIST_DIR/$DMG_NAME   ← 用户双击后拖到「应用程序」"
fi
echo "  可选：brew install create-dmg 以获得更稳定的 DMG 窗口布局"
echo "  详见 docs/RELEASE.md"
