#!/usr/bin/env bash
# 将 icon-variants/ 源图同步进 Asset Catalog（AppIcon / BarIcon）。
# 用法：./scripts/sync-icons.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_SRC="$ROOT/icon-variants/app-icon.png"
BAR_SRC="$ROOT/icon-variants/bar-icon.png"
APP_DEST="$ROOT/SnapFlow/Resources/Assets.xcassets/AppIcon.appiconset"
BAR_DEST="$ROOT/SnapFlow/Resources/Assets.xcassets/BarIcon.imageset"

if [[ ! -f "$APP_SRC" ]]; then
  echo "缺少源图: $APP_SRC" >&2
  exit 1
fi

echo "==> Sync AppIcon from icon-variants/app-icon.png"
mkdir -p "$APP_DEST"
sips -z 16 16   "$APP_SRC" --out "$APP_DEST/icon_16x16.png" >/dev/null
sips -z 32 32   "$APP_SRC" --out "$APP_DEST/icon_16x16@2x.png" >/dev/null
sips -z 32 32   "$APP_SRC" --out "$APP_DEST/icon_32x32.png" >/dev/null
sips -z 64 64   "$APP_SRC" --out "$APP_DEST/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$APP_SRC" --out "$APP_DEST/icon_128x128.png" >/dev/null
sips -z 256 256 "$APP_SRC" --out "$APP_DEST/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$APP_SRC" --out "$APP_DEST/icon_256x256.png" >/dev/null
sips -z 512 512 "$APP_SRC" --out "$APP_DEST/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$APP_SRC" --out "$APP_DEST/icon_512x512.png" >/dev/null
cp "$APP_SRC" "$APP_DEST/icon_512x512@2x.png"
# 清理旧的单文件命名，避免误用
rm -f "$APP_DEST/app-icon.png"

if [[ -f "$BAR_SRC" ]]; then
  echo "==> Sync BarIcon from icon-variants/bar-icon.png"
  mkdir -p "$BAR_DEST"
  W=$(sips -g pixelWidth "$BAR_SRC" | awk '/pixelWidth/{print $2}')
  H=$(sips -g pixelHeight "$BAR_SRC" | awk '/pixelHeight/{print $2}')
  W1=$((W / 2)); H1=$((H / 2))
  [[ "$W1" -lt 1 ]] && W1=1
  [[ "$H1" -lt 1 ]] && H1=1
  sips -z "$H1" "$W1" "$BAR_SRC" --out "$BAR_DEST/bar-icon.png" >/dev/null
  cp "$BAR_SRC" "$BAR_DEST/bar-icon@2x.png"
fi

echo "==> Done. 请重新 Build / 运行 package-release.sh 使 Assets.car 生效。"
echo "    若 Finder 仍显示旧图标：rm -rf dist build/SnapFlowReleaseDerivedData && 清图标缓存后重开。"
