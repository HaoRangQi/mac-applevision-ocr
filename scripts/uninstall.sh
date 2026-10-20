#!/bin/bash
# 卸载命令与共享数据（不会删除仓库本身）
set -euo pipefail
PREFIX="${PREFIX:-$HOME/.local}"
rm -f "$PREFIX/bin/applevision-ocr"
rm -rf "$PREFIX/share/applevision-ocr"
echo "removed: $PREFIX/bin/applevision-ocr, $PREFIX/share/applevision-ocr"
