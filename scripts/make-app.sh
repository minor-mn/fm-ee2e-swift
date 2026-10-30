#!/bin/sh
# GUI 版を .app にまとめる。できた fm-ee2e.app は、/Applications などに置いて使う。
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product fm-ee2e
app=.build/fm-ee2e.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/fm-ee2e "$app/Contents/MacOS/fm-ee2e"
# アイコン。scripts/make-icon.swift で描いた絵から、大きさごとの絵を作って .icns にまとめる。
icons=.build/AppIcon.iconset
rm -rf "$icons"
mkdir -p "$icons" "$app/Contents/Resources"
swift scripts/make-icon.swift .build/AppIcon.png
for n in 16 32 128 256 512; do
  sips -z $n $n .build/AppIcon.png --out "$icons/icon_${n}x${n}.png" >/dev/null
  sips -z $((n * 2)) $((n * 2)) .build/AppIcon.png --out "$icons/icon_${n}x${n}@2x.png" >/dev/null
done
iconutil -c icns "$icons" -o "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>fm-ee2e</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>local.fm-ee2e</string>
  <key>CFBundleName</key>
  <string>fm-ee2e-swift</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST
echo "$app"
