#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
APP="$PWD/build/SongNote.app"
VERSION="$(tr -d '\r\n' < VERSION)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" -O -framework AppKit -framework QuartzCore -framework ServiceManagement -framework CryptoKit -framework Carbon \
    macos/Models.swift macos/Texts.swift macos/AttachmentFiles.swift macos/Store.swift macos/SyncClient.swift macos/Theme.swift \
    macos/NoteWindow.swift macos/CompareWindow.swift macos/HotKey.swift macos/LayoutChecks.swift macos/App.swift -o "$APP/Contents/MacOS/SongNote"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SongNote</string>
<key>CFBundleIdentifier</key><string>cn.songnote.mac</string>
<key>CFBundleName</key><string>SongNote</string>
<key>CFBundleDisplayName</key><string>SongNote 便签</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The private sync key is never bundled; the app asks for client-config.json on first launch.
rm -f "$APP/Contents/Resources/client-config.json"
codesign --force --sign - "$APP"
echo "$APP"
