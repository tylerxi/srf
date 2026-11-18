#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh
APP="/Applications/SilentClipboard.app"
if [ -x "$APP/Contents/MacOS/SilentClipboard" ]; then
  "$APP/Contents/MacOS/SilentClipboard" --ctl quit >/dev/null 2>&1 || true
  sleep 1
fi
ditto build/SilentClipboard.app "$APP"
ditto "build/SilentClipboard Settings.app" "/Applications/SilentClipboard Settings.app"
open -gj "$APP"
printf 'Installed %s\n' "$APP"
