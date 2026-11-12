#!/bin/sh
# Builds the public DMG: clean Release build, re-signed ad-hoc (no developer identity or email
# in the signature), packaged with dmgbuild into dist/Spatialize-<version>.dmg.
# Run from anywhere: dmg/build.sh
set -eu
cd "$(dirname "$0")/.."

xcodegen generate
xcodebuild -project Spatialize.xcodeproj -scheme Spatialize -configuration Release \
    -derivedDataPath build -allowProvisioningUpdates -quiet clean build

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto build/Build/Products/Release/Spatialize.app "$STAGE/Spatialize.app"
codesign --force --sign - "$STAGE/Spatialize.app"
codesign --verify --strict "$STAGE/Spatialize.app"

VERSION=$(plutil -extract CFBundleShortVersionString raw "$STAGE/Spatialize.app/Contents/Info.plist")
mkdir -p dist
uv run --with dmgbuild dmgbuild -s dmg/settings.py -D app="$STAGE/Spatialize.app" Spatialize "dist/Spatialize-$VERSION.dmg"
hdiutil verify "dist/Spatialize-$VERSION.dmg"
echo "Built dist/Spatialize-$VERSION.dmg"
