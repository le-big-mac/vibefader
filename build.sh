#!/bin/bash
# Build VibeFader in Release mode and install to /Applications
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

echo "Building VibeFader (Release)..."
xcodebuild -project VibeFader.xcodeproj \
  -scheme VibeFader \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tail -3

# Find the built app in DerivedData
APP_PATH=$(xcodebuild -project VibeFader.xcodeproj -scheme VibeFader -configuration Release -showBuildSettings 2>/dev/null | grep "BUILT_PRODUCTS_DIR" | head -1 | awk '{print $3}')
APP_PATH="$APP_PATH/VibeFader.app"

if [ ! -d "$APP_PATH" ]; then
  echo "Build failed — app not found"
  exit 1
fi

echo ""
echo "Signing..."
xattr -cr "$APP_PATH"
codesign --force --deep --sign - "$APP_PATH"

echo ""
echo "Installing to /Applications..."
rm -rf /Applications/VibeFader.app
cp -R "$APP_PATH" /Applications/VibeFader.app

echo ""
echo "Setting up permissions..."
bash "$SCRIPT_DIR/setup-permissions.sh"

echo ""
echo "VibeFader installed to /Applications/VibeFader.app"
