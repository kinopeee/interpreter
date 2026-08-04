#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${ROOT}/build/DerivedData/Build/Products/Debug/RealtimeTranslator.app"
APP_EXECUTABLE="${APP}/Contents/MacOS/RealtimeTranslator"
STATUS_FILE="/tmp/realtimetranslator.status"
LOCK_FILE="${HOME}/Library/Application Support/com.realtimetranslator.app/instance.lock"

pid_is_running() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

find_running_pid() {
  local pid=""

  if [[ -e "$LOCK_FILE" ]] && [[ -x /usr/sbin/lsof ]]; then
    IFS= read -r pid < <(/usr/sbin/lsof -t "$LOCK_FILE" 2>/dev/null || true)
    if pid_is_running "$pid"; then
      echo "$pid"
      return
    fi
  fi
  pid=""
  if [[ -r "$LOCK_FILE" ]]; then
    IFS= read -r pid < "$LOCK_FILE" || true
    if pid_is_running "$pid"; then
      echo "$pid"
      return
    fi
  fi
  pid=""
  if [[ -x /usr/bin/pgrep ]]; then
    IFS= read -r pid < <(/usr/bin/pgrep -f "^${APP_EXECUTABLE}$" 2>/dev/null || true)
    if pid_is_running "$pid"; then
      echo "$pid"
    fi
  fi
}

stop_running_instance() {
  local pid="$1"
  local command_line
  command_line="$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)"
  if [[ "$command_line" != *"/RealtimeTranslator.app/Contents/MacOS/RealtimeTranslator"* ]]; then
    echo "Refusing to stop unexpected lock owner PID ${pid}: ${command_line}" >&2
    exit 1
  fi

  echo "Stopping existing RealtimeTranslator (PID ${pid})..."
  kill -TERM "$pid"
  for ((attempt = 0; attempt < 100; attempt++)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      return
    fi
    sleep 0.05
  done
  echo "Existing RealtimeTranslator did not stop in time." >&2
  exit 1
}

echo "Building RealtimeTranslator..."
(cd "$ROOT" && xcodegen generate && xcodebuild \
  -scheme RealtimeTranslator \
  -destination 'platform=macOS' \
  -derivedDataPath ./build/DerivedData \
  build)

while running_pid="$(find_running_pid)" && [[ -n "$running_pid" ]]; do
  stop_running_instance "$running_pid"
done
/bin/rm -f "$STATUS_FILE"

echo "Starting RealtimeTranslator..."
echo "Status file: $STATUS_FILE"
echo "字幕上の「録音開始」ボタンを押してから話してください。"
exec /usr/bin/open -n -W "$APP"
