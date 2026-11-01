#!/bin/sh
# 하늘다람쥐.app 을 빌드해서 ~/Applications 에 설치
set -e
cd "$(dirname "$0")"
swiftc -O -swift-version 5 main.swift -o Squirrel

I=$(mktemp -d)/AppIcon.iconset; mkdir -p "$I"
./Squirrel --icon "$I/../icon.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$I/../icon.png" --out "$I/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$I/../icon.png" --out "$I/icon_${s}x${s}@2x.png" >/dev/null
done

A="하늘다람쥐.app"; rm -rf "$A"; mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources"
iconutil -c icns "$I" -o "$A/Contents/Resources/AppIcon.icns"
cp Squirrel "$A/Contents/MacOS/Squirrel"
cat > "$A/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>하늘다람쥐</string>
<key>CFBundleDisplayName</key><string>하늘다람쥐</string>
<key>CFBundleIdentifier</key><string>local.desktop.flyingsquirrel</string>
<key>CFBundleExecutable</key><string>Squirrel</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>지금 듣는 노래를 알아내서 따라 부르려고 해요.</string>
</dict></plist>
PLIST
codesign --force --deep -s - "$A"
mkdir -p ~/Applications && rm -rf ~/Applications/"$A" && cp -R "$A" ~/Applications/
echo "설치 완료: ~/Applications/$A"
