#!/bin/bash
# 编译 OCR 引擎（Swift + Vision）到 bin/ocrvision
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/bin"
swiftc -O "$ROOT/src/engine/ocrvision.swift" -o "$ROOT/bin/ocrvision"
echo "engine: $ROOT/bin/ocrvision"
