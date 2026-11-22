#!/bin/zsh
# Build "Session Keeper for Claude.app" (universal: Apple Silicon + Intel).
#   ./app/build.sh            build into app/build/ and zip into dist/
#   ./app/build.sh --install  also copy the app into /Applications (or ~/Applications)
set -e
cd "$(dirname "$0")"
ROOT=".."
NAME="Session Keeper for Claude"
APP="build/$NAME.app"
VERSION="${VERSION:-1.0.0}"

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target "$arch-apple-macos14" -o "build/SessionKeeper-$arch" main.swift
done
lipo -create -output "$APP/Contents/MacOS/SessionKeeper" build/SessionKeeper-arm64 build/SessionKeeper-x86_64
rm build/SessionKeeper-*

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>local.claude-session-vault.app</string>
  <key>CFBundleExecutable</key><string>SessionKeeper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
R="$APP/Contents/Resources"
cp AppIcon.icns "$R/"
cp "$ROOT/claude_sessions.py" "$R/"
cp "$ROOT/config.default.json" "$R/"
mkdir -p "$R/en.lproj" "$R/zh-Hans.lproj"
printf '"CFBundleDisplayName" = "%s";\n"CFBundleName" = "%s";\n' "$NAME" "$NAME" > "$R/en.lproj/InfoPlist.strings"
printf '"CFBundleDisplayName" = "Claude 换号助手";\n"CFBundleName" = "Claude 换号助手";\n' > "$R/zh-Hans.lproj/InfoPlist.strings"
codesign --force --deep --sign - "$APP"

mkdir -p "$ROOT/dist"
rm -f "$ROOT/dist/SessionKeeper-macOS.zip"
ditto -c -k --keepParent "$APP" "$ROOT/dist/SessionKeeper-macOS.zip"
echo "Built: app/$APP"
echo "Zip:   dist/SessionKeeper-macOS.zip"

if [[ "$1" == "--install" ]]; then
  DEST="/Applications"; [[ -w "$DEST" ]] || DEST="$HOME/Applications"; mkdir -p "$DEST"
  rm -rf "$DEST/$NAME.app" "$DEST/Claude 换号恢复.app"
  cp -R "$APP" "$DEST/"
  echo "Installed: $DEST/$NAME.app"
fi
