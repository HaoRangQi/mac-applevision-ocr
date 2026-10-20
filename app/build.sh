#!/bin/bash
# 打包 AppleVisionOCR.app
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
APP="dist/AppleVisionOCR.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library -o "$APP/Contents/MacOS/AppleVisionOCR" AppleVisionOCRApp.swift

# 把识别包与引擎打进 app，使其自包含
cp -R "$ROOT/src/applevision_ocr" "$APP/Contents/Resources/applevision_ocr"
[ -x "$ROOT/bin/ocrvision" ] || "$ROOT/scripts/build-engine.sh"
cp "$ROOT/bin/ocrvision" "$APP/Contents/Resources/ocrvision"
chmod +x "$APP/Contents/Resources/ocrvision"

sed -e 's/__NAME__/AppleVisionOCR/g' -e 's/__ID__/local.applevisionocr.app/g' Info.plist.tmpl > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
[ -f AppIcon.icns ] || "$ROOT/scripts/build-icon.sh"
cp AppIcon.icns "$APP/Contents/Resources/"

codesign --force --deep --sign - "$APP" 2>/dev/null || true
echo "built: $APP"
