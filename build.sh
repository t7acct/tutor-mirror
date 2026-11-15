#!/bin/zsh
# Builds TutorMirror.app into ./build.
#
#   ./build.sh              build for this Mac
#   ./build.sh --run        build and (re)launch
#   ./build.sh --install    build, copy to /Applications and launch it from there
#   ./build.sh --release    universal (Apple Silicon + Intel), ad-hoc signed,
#                           zipped to build/TutorMirror.zip for sharing
#   ./build.sh --test       a separate "TutorMirror Test" copy (own bundle ID,
#                           settings, ports and receiver name) that can run next
#                           to the real app, e.g. while it's in use for a lesson.
#                           Combine with --run. Never touches the real app.
set -euo pipefail
cd "$(dirname "$0")"

RUN=0; RELEASE=0; INSTALL=0; TEST=0
for arg in "$@"; do
  case $arg in
    --run) RUN=1 ;;
    --release) RELEASE=1 ;;
    --install) INSTALL=1 ;;
    --test) TEST=1 ;;
    *) echo "unknown option $arg"; exit 1 ;;
  esac
done

if (( TEST )); then
  if (( RELEASE || INSTALL )); then echo "--test can't be combined with --release or --install"; exit 1; fi
  NAME="TutorMirror Test"; EXE=TutorMirrorTest; BUNDLE_ID=local.tutormirror.test; OBJROOT=build/obj-test
else
  NAME=TutorMirror; EXE=TutorMirror; BUNDLE_ID=local.tutormirror; OBJROOT=build/obj
fi
APP="build/$NAME.app"
rm -rf "$APP" "$OBJROOT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SDK=$(xcrun --show-sdk-path --sdk macosx)
if (( RELEASE )); then
  ARCHS=(arm64 x86_64)
elif [[ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null)" == 1 ]]; then
  # uname reports the shell's architecture when it runs under Rosetta.
  ARCHS=(arm64)
else
  ARCHS=(x86_64)
fi

# Keep this machine's folder paths out of the binary.
ROOT=$(pwd)
PREFIX_MAP=("-file-prefix-map" "$ROOT=.")

BINS=()
for ARCH in $ARCHS; do
  TARGET=$ARCH-apple-macos14.0
  OBJ=$OBJROOT/$ARCH
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
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/$EXE"

cp Resources/Info.plist "$APP/Contents/Info.plist"
if (( TEST )); then
  PB=/usr/libexec/PlistBuddy
  $PB -c "Set :CFBundleIdentifier $BUNDLE_ID" -c "Set :CFBundleExecutable $EXE" \
      -c "Set :CFBundleName $NAME" -c "Set :CFBundleDisplayName $NAME" "$APP/Contents/Info.plist"
fi
# The icon source is Resources/AppIcon.icon (Icon Composer). With Xcode
# installed it's compiled so macOS 26+ can draw its light, dark, clear and
# tinted styles; without Xcode the prebuilt flat AppIcon.icns is used.
if xcrun --find actool >/dev/null 2>&1; then
  # Full paths: actool resolves relative ones against its helper's folder.
  ICON_LOG=$(xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" \
    --app-icon AppIcon --include-all-app-icons --platform macosx --target-device mac \
    --minimum-deployment-target 14.0 --enable-on-demand-resources NO --development-region en \
    --output-partial-info-plist "$PWD/$OBJROOT/icon-info.plist" --errors 2>&1) || true
  if [[ ! -f "$APP/Contents/Resources/Assets.car" ]]; then
    echo "$ICON_LOG"; echo "Couldn't compile the app icon"; exit 1
  fi
else
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

if (( RELEASE )); then
  # Ad-hoc signature: no developer certificate (and so no personal details) inside.
  codesign --force --sign - "$APP"
  rm -f build/TutorMirror.zip
  # --norsrc: leave out macOS file metadata, which other unzip tools would
  # unpack as stray ._ files that break the signature.
  ditto -c -k --norsrc --keepParent "$APP" build/TutorMirror.zip
  echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/TutorMirror")) and build/TutorMirror.zip"
else
  # Local builds: sign with your Apple Development certificate if you have one,
  # which keeps the Local Network permission stable across rebuilds.
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/{print $2; exit}')
  codesign --force --sign "${IDENTITY:--}" --timestamp=none "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP"
  echo "Built $APP"
fi

if (( RUN )); then
  # Only ever stops the copy being rebuilt (the test copy has its own process name).
  pkill -x "$EXE" 2>/dev/null || true
  open "$APP"
fi

if (( INSTALL )); then
  pkill -x TutorMirror 2>/dev/null || true
  rm -rf /Applications/TutorMirror.app
  ditto "$APP" /Applications/TutorMirror.app
  echo "Installed /Applications/TutorMirror.app"
  open /Applications/TutorMirror.app
fi
