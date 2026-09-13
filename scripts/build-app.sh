#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --configuration release
bundle="$PWD/dist/Orb.app"
mkdir -p "$bundle/Contents/MacOS"
cp .build/release/Orb "$bundle/Contents/MacOS/Orb"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
codesign --force --sign - "$bundle"
printf 'Built %s\n' "$bundle"
