#!/bin/bash
# 由 app/icon.swift 生成 AppIcon.icns
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/app"
swiftc -O icon.swift -o /tmp/applevision-ocr-icon
/tmp/applevision-ocr-icon >/dev/null
rm -rf AppIcon.iconset && mkdir -p AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s icon_1024.png --out AppIcon.iconset/icon_${s}x${s}.png >/dev/null
  d=$((s * 2))
  sips -z $d $d icon_1024.png --out AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns AppIcon.iconset -o AppIcon.icns
echo "icon: $ROOT/app/AppIcon.icns"
