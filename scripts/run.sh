#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${ROOT}/build/DerivedData/Build/Products/Debug/RealtimeTranslator.app"
BIN="${APP}/Contents/MacOS/RealtimeTranslator"
STATUS_FILE="/tmp/realtimetranslator.status"

if [[ ! -x "$BIN" ]]; then
  echo "Building RealtimeTranslator..."
  (cd "$ROOT" && xcodegen generate && xcodebuild \
    -scheme RealtimeTranslator \
    -destination 'platform=macOS' \
    -derivedDataPath ./build/DerivedData \
    build)
fi

pkill -f "${BIN}" 2>/dev/null || true
rm -f "$STATUS_FILE"
sleep 0.2

echo "Starting RealtimeTranslator..."
echo "Status file: $STATUS_FILE"
echo "字幕上の「録音開始」ボタンを押してから話してください。"
exec /usr/bin/open -W "$APP"
