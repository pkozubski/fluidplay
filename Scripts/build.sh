#!/bin/zsh
# Builds FluidPlay.app into build/ and signs it (development build for this Mac).
# Usage: Scripts/build.sh [Debug|Release]
# For a distributable build use Scripts/release.sh.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIGURATION="${1:-Release}"
DERIVED="build/DerivedData"
APP="build/FluidPlay.app"

xcodegen generate --quiet

xcodebuild -project FluidPlay.xcodeproj -scheme FluidPlay -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED" -destination 'platform=macOS,arch=arm64' build \
  | grep -E "error|warning: |BUILD (SUCCEEDED|FAILED)" || true

BUILT="$DERIVED/Build/Products/$CONFIGURATION/FluidPlay.app"
if [[ ! -d "$BUILT" ]]; then
  echo "Build failed." >&2
  exit 1
fi

rm -rf "$APP"
cp -R "$BUILT" "$APP"

# The copy in DerivedData is not signed with our identity. If it stayed, macOS would treat it as a
# different app with the same bundle ID and ask for permissions (Screen Recording, Local Network)
# every time it ran. Only build/FluidPlay.app is kept.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$BUILT" 2>/dev/null || true
if pgrep -f "$PWD/$BUILT/Contents/MacOS" >/dev/null; then
  echo "Note: the DerivedData copy is running — it will be removed by the next build after it quits."
else
  rm -rf "$BUILT"
fi

# A stable signing identity lets macOS remember the Screen Recording permission between rebuilds.
# Without one the app is signed ad hoc (the permission has to be granted again after every rebuild).
IDENTITY="${FLUIDPLAY_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/^ *1\)/ {print $2}')}"
if [[ -n "$IDENTITY" ]]; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
  echo "Signed with identity $IDENTITY"
else
  codesign --force --deep --sign - "$APP"
  echo "Signed ad hoc"
fi

"$LSREGISTER" -f "$APP" 2>/dev/null || true
echo "Done: $APP"
