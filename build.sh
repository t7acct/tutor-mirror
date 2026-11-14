#!/bin/zsh
# Builds TutorMirror.app into ./build. Usage: ./build.sh [--run]
set -euo pipefail
cd "$(dirname "$0")"

APP=build/TutorMirror.app
OBJ=build/obj
rm -rf "$APP"
mkdir -p "$OBJ" "$APP/Contents/MacOS" "$APP/Contents/Resources"

TARGET=arm64-apple-macos14.0
SDK=$(xcrun --show-sdk-path --sdk macosx)

# FairPlay C code (from VirtualMirror / UxPlay)
for c in Sources/FairPlay/*.c; do
  xcrun clang -O2 -target $TARGET -isysroot "$SDK" -w -c "$c" -o "$OBJ/$(basename "${c%.c}").o"
done

xcrun swiftc -O -wmo -swift-version 5 -target $TARGET -sdk "$SDK" \
  -import-objc-header Sources/FairPlay/BridgingHeader.h -I Sources/FairPlay \
  $(find Sources -name '*.swift') "$OBJ"/*.o \
  -o "$APP/Contents/MacOS/TutorMirror"

cp Resources/Info.plist "$APP/Contents/Info.plist"

# Sign with your Apple Development certificate if there is one (keeps the
# Local Network permission stable across rebuilds), otherwise ad-hoc.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/{print $2; exit}')
codesign --force --sign "${IDENTITY:--}" --timestamp=none "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP"

echo "Built $APP"
if [[ "${1:-}" == "--run" ]]; then
  pkill -x TutorMirror 2>/dev/null || true
  open "$APP"
fi
