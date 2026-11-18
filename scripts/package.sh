#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh
mkdir -p release build/distribution
# Each package contains both independently launchable apps.
ditto build/SilentClipboard.app build/distribution/SilentClipboard.app
ditto "build/SilentClipboard Settings.app" "build/distribution/SilentClipboard Settings.app"
ditto -c -k --sequesterRsrc build/distribution release/SilentClipboard-0.2.0-arm64.zip
shasum -a 256 release/SilentClipboard-0.2.0-arm64.zip > release/SHA256SUMS
printf 'Packaged release/SilentClipboard-0.2.0-arm64.zip\n'
