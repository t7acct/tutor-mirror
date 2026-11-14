#!/bin/zsh
# Publishes the version in Resources/Info.plist as a GitHub release. Everyone
# running TutorMirror 0.2.0 or later is offered it by the app's updater
# (Check for Updates…), which downloads the TutorMirror.zip attached here.
#
#   1. Bump CFBundleShortVersionString (and CFBundleVersion) in Resources/Info.plist
#   2. Commit
#   3. ./release.sh "What's new, shown in the update prompt"
#
# Needs the GitHub CLI (gh), signed in.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
TAG="v$VERSION"
NOTES=${1:-}

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Commit your changes first."; exit 1
fi
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "$TAG is already released. Bump CFBundleShortVersionString in Resources/Info.plist."; exit 1
fi

./build.sh --release
git push origin HEAD
if [[ -n $NOTES ]]; then
  gh release create "$TAG" build/TutorMirror.zip --title "TutorMirror $VERSION" --notes "$NOTES" --target "$(git rev-parse HEAD)"
else
  gh release create "$TAG" build/TutorMirror.zip --title "TutorMirror $VERSION" --generate-notes --target "$(git rev-parse HEAD)"
fi
echo "Released $TAG. Apps on 0.2.0+ will offer it next time they check."
