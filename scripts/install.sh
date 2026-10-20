#!/bin/bash
# 安装到 ~/.local：命令 vision-ocr、共享数据 ~/.local/share/vision-ocr
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
SHARE="$PREFIX/share/vision-ocr"
BIN="$PREFIX/bin"

"$ROOT/scripts/build-engine.sh"

mkdir -p "$SHARE" "$BIN"
rm -rf "$SHARE/vision_ocr"
cp -R "$ROOT/src/vision_ocr" "$SHARE/vision_ocr"
cp "$ROOT/bin/ocrvision" "$SHARE/ocrvision"
chmod +x "$SHARE/ocrvision"

cat > "$BIN/vision-ocr" <<'LAUNCHER'
#!/bin/sh
# vision-ocr launcher
SHARE="${VISION_OCR_HOME:-$HOME/.local/share/vision-ocr}"
PY="${VISION_OCR_PYTHON:-$(command -v python3)}"
if [ -z "$PY" ]; then
  echo "vision-ocr: 需要 python3" >&2
  exit 1
fi
PYTHONPATH="$SHARE${PYTHONPATH:+:$PYTHONPATH}" exec "$PY" -m vision_ocr "$@"
LAUNCHER
chmod +x "$BIN/vision-ocr"

echo "installed: $BIN/vision-ocr"
echo "data:      $SHARE"
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "注意：$BIN 不在 PATH 中" ;;
esac
