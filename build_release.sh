#!/bin/zsh
# Build a Release copy of NegConv (Apple Silicon + Intel) and zip it into dist/.
# Usage: ./build_release.sh
set -euo pipefail
cd "$(dirname "$0")"

rm -rf build
xcodebuild -project NegConv.xcodeproj -target NegConv -configuration Release \
  ONLY_ACTIVE_ARCH=NO ARCHS="arm64 x86_64" \
  CODE_SIGN_IDENTITY=- SYMROOT="$PWD/build" \
  build | grep -E "error:|warning:|BUILD" || true

APP="build/Release/NegConv.app"
[[ -d "$APP" ]] || { echo "Build failed — no $APP"; exit 1; }

VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")
mkdir -p dist
ZIP="dist/NegConv-$VER-$BUILD.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Built: $ZIP ($(du -h "$ZIP" | cut -f1))"
lipo -archs "$APP/Contents/MacOS/NegConv" | sed 's/^/Architectures: /'
