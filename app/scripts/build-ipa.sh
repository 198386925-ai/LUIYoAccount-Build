#!/bin/bash
# Build unsigned LUIYoAccount IPA from repository source (macOS runner).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP_NAME=LUIYoAccount

xcodebuild -version

mkdir -p output
xcodebuild \
  -project LUIYoAccount.xcodeproj \
  -scheme LUIYoAccount -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon build

APP="build/Build/Products/Release-iphoneos/${APP_NAME}.app"
test -f "$APP/$APP_NAME"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")

STAGE=$(mktemp -d "$ROOT/build/package.XXXXXX")
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
NAME="${APP_NAME}-${VERSION}-Build(${BUILD}).ipa"
(cd "$STAGE" && /usr/bin/zip -qry "$ROOT/output/$NAME" Payload)
unzip -t "output/$NAME"

# Clean source backup zip (full real source only; no build artifacts, no git metadata).
SRC_NAME="${APP_NAME}-${VERSION}-Build(${BUILD})-src.zip"
(cd "$ROOT" && /usr/bin/zip -qry "output/$SRC_NAME" . -x 'build/*' -x 'output/*' -x '.git/*' -x '.gitignore')
unzip -t "output/$SRC_NAME"

echo "IPA: output/$NAME (unsigned; sign before installation)"
echo "SRC: output/$SRC_NAME"
