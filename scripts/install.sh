#!/bin/bash
# 安装到 ~/.local：命令 applevision-ocr、共享数据 ~/.local/share/applevision-ocr
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
SHARE="$PREFIX/share/applevision-ocr"
BIN="$PREFIX/bin"

"$ROOT/scripts/build-engine.sh"

mkdir -p "$SHARE" "$BIN"
rm -rf "$SHARE/applevision_ocr"
cp -R "$ROOT/src/applevision_ocr" "$SHARE/applevision_ocr"
cp "$ROOT/bin/ocrvision" "$SHARE/ocrvision"
chmod +x "$SHARE/ocrvision"

cat > "$BIN/applevision-ocr" <<'LAUNCHER'
#!/bin/sh
# applevision-ocr launcher
SHARE="${APPLEVISION_OCR_HOME:-$HOME/.local/share/applevision-ocr}"
PY="${APPLEVISION_OCR_PYTHON:-$(command -v python3)}"
if [ -z "$PY" ]; then
  echo "applevision-ocr: 需要 python3" >&2
  exit 1
fi
PYTHONPATH="$SHARE${PYTHONPATH:+:$PYTHONPATH}" exec "$PY" -m applevision_ocr "$@"
LAUNCHER
chmod +x "$BIN/applevision-ocr"

echo "installed: $BIN/applevision-ocr"
echo "data:      $SHARE"
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "注意：$BIN 不在 PATH 中" ;;
esac
