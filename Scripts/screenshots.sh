#!/bin/zsh
# Regenerates the README images in docs/ from the real app UI.
set -e
cd "$(dirname "$0")/.."
./build.sh >/dev/null
BIN=build/FloatChat.app/Contents/MacOS/FloatChat
TMP=$(mktemp -d)
snap() { FLOATCHAT_SNAPSHOT=$TMP/$1.png FLOATCHAT_APPEARANCE=$2 $BIN -AppleLanguages "($3)" }
snap en-light light en
snap en-dark dark en
snap zh-light light zh-Hans
snap zh-dark dark zh-Hans
swift Scripts/frame-screenshot.swift banner $TMP/en-light.png docs/banner.png "FloatChat" \
  "Claude Code and Codex in a tiny\nwindow that floats above everything." "⌥ Space"
swift Scripts/frame-screenshot.swift banner $TMP/zh-light.png docs/banner.zh-CN.png "FloatChat" \
  "把 Claude Code 和 Codex\n装进一个随叫随到的悬浮小窗" "⌥ Space"
swift Scripts/frame-screenshot.swift pair $TMP/en-light.png $TMP/en-dark.png docs/light-dark.png
swift Scripts/frame-screenshot.swift pair $TMP/zh-light.png $TMP/zh-dark.png docs/light-dark.zh-CN.png
rm -rf "$TMP"
# JPEG keeps the README light; these images have no transparency
for f in banner banner.zh-CN light-dark light-dark.zh-CN; do
  sips -s format jpeg -s formatOptions 88 docs/$f.png --out docs/$f.jpg >/dev/null && rm docs/$f.png
done
