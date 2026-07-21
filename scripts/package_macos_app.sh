#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="newMosaic"
EXECUTABLE_NAME="NewMosaicApp"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

cd "$ROOT_DIR"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp ".build/release/$EXECUTABLE_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"

# SwiftPMリソースバンドル（アニメ部位検出ONNXモデル等）を同梱する。
# Bundle.module は実行ファイルと同じディレクトリのバンドルも探すため MacOS/ 直下へ配置する。
cp -R ".build/release/newMosaic_MosaicCore.bundle" "$MACOS_DIR/"

# SwiftPM生成のバンドルには Info.plist が無く、codesign が「bundle format unrecognized」で
# 失敗するため、最小限の Info.plist を付与して個別に署名しておく。
cat > "$MACOS_DIR/newMosaic_MosaicCore.bundle/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>jp.yoshikawa303.newMosaic.MosaicCoreResources</string>
  <key>CFBundleName</key>
  <string>newMosaic_MosaicCore</string>
  <key>CFBundlePackageType</key>
  <string>BNDL</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$MACOS_DIR/newMosaic_MosaicCore.bundle" >/dev/null

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>ja_JP</string>
  <key>CFBundleDisplayName</key>
  <string>newMosaic</string>
  <key>CFBundleExecutable</key>
  <string>NewMosaicApp</string>
  <key>CFBundleIdentifier</key>
  <string>jp.yoshikawa303.newMosaic</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>newMosaic</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.0.00001</string>
  <key>CFBundleVersion</key>
  <string>38</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSRemovableVolumesUsageDescription</key>
  <string>アプリ本体がリムーバブルボリューム上にある場合、同梱の検出モデルを初回に内蔵ディスクへコピーするためアクセスします。</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP_DIR" >/dev/null
echo "$APP_DIR"
