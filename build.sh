#!/bin/zsh
# Builds a universal release binary and packages it as build/FloatChat.app
set -e
cd "$(dirname "$0")"
# Build each architecture on its own and merge with lipo; this works with just the Command Line Tools
for triple in arm64-apple-macosx14.0 x86_64-apple-macosx14.0; do
  swift build -c release --triple $triple
done
BIN=$(mktemp -d)
lipo -create -output "$BIN/FloatChat" \
  "$(swift build -c release --triple arm64-apple-macosx14.0 --show-bin-path)/FloatChat" \
  "$(swift build -c release --triple x86_64-apple-macosx14.0 --show-bin-path)/FloatChat"
APP=build/FloatChat.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/FloatChat" "$APP/Contents/MacOS/FloatChat"
cp -R Resources/ "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>FloatChat</string>
  <key>CFBundleDisplayName</key><string>FloatChat</string>
  <key>CFBundleIdentifier</key><string>io.github.evihut.FloatChat</string>
  <key>CFBundleExecutable</key><string>FloatChat</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.4.0</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP ($(du -sh "$APP" | cut -f1))"
