#!/bin/zsh
# Builds TutorMirror.app into ./build.
#
#   ./build.sh              build for this Mac
#   ./build.sh --run        build and (re)launch
#   ./build.sh --release    universal (Apple Silicon + Intel), ad-hoc signed,
#                           zipped to build/TutorMirror.zip for sharing
set -euo pipefail
cd "$(dirname "$0")"

RUN=0; RELEASE=0
for arg in "$@"; do
  case $arg in
    --run) RUN=1 ;;
    --release) RELEASE=1 ;;
    *) echo "unknown option $arg"; exit 1 ;;
  esac
done

APP=build/TutorMirror.app
rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SDK=$(xcrun --show-sdk-path --sdk macosx)
if (( RELEASE )); then ARCHS=(arm64 x86_64); else ARCHS=($(uname -m)); fi

# Keep this machine's folder paths out of the binary.
ROOT=$(pwd)
PREFIX_MAP=("-file-prefix-map" "$ROOT=.")

BINS=()
for ARCH in $ARCHS; do
  TARGET=$ARCH-apple-macos14.0
  OBJ=build/obj/$ARCH
  mkdir -p "$OBJ"

  # FairPlay C code (from VirtualMirror / UxPlay)
  for c in Sources/FairPlay/*.c; do
    xcrun clang -O2 -target $TARGET -isysroot "$SDK" -ffile-prefix-map="$ROOT=." -w \
      -c "$c" -o "$OBJ/$(basename "${c%.c}").o"
  done

  xcrun swiftc -O -wmo -swift-version 5 -target $TARGET -sdk "$SDK" "${PREFIX_MAP[@]}" \
    -import-objc-header Sources/FairPlay/BridgingHeader.h -I Sources/FairPlay \
    $(find Sources -name '*.swift') "$OBJ"/*.o \
    -o "$OBJ/TutorMirror"
  BINS+=("$OBJ/TutorMirror")
done
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/TutorMirror"

cp Resources/Info.plist "$APP/Contents/Info.plist"

if (( RELEASE )); then
  # Ad-hoc signature: no developer certificate (and so no personal details) inside.
  codesign --force --sign - "$APP"
  rm -f build/TutorMirror.zip
  ditto -c -k --keepParent "$APP" build/TutorMirror.zip
  echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/TutorMirror")) and build/TutorMirror.zip"
else
  # Local builds: sign with your Apple Development certificate if you have one,
  # which keeps the Local Network permission stable across rebuilds.
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/{print $2; exit}')
  codesign --force --sign "${IDENTITY:--}" --timestamp=none "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP"
  echo "Built $APP"
fi

if (( RUN )); then
  pkill -x TutorMirror 2>/dev/null || true
  open "$APP"
fi
