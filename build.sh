#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="build/DV Capture.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Licenses"
make -C tapecap -j4 ARCHS='-arch arm64'
cp tapecap/build/tapecap "$app/Contents/MacOS/tapecap"
cp Info.plist "$app/Contents/Info.plist"
cp live_session.py "$app/Contents/Resources/live_session.py"
cp audio_export.py "$app/Contents/Resources/audio_export.py"
cp tapecap/LICENSE "$app/Contents/Resources/Licenses/tapecap.txt"
cp tapecap/third_party/AVCVideoServices/NOTICE.md "$app/Contents/Resources/Licenses/Apple-Provenance.txt"
sed -n '1,45p' tapecap/third_party/AVCVideoServices/DVReceiver.cpp > "$app/Contents/Resources/Licenses/Apple.txt"
mkdir -p build/module-cache
xcrun swiftc -target arm64-apple-macos13.0 -module-cache-path build/module-cache -swift-version 5 -parse-as-library -O DVCapture.swift -o "$app/Contents/MacOS/DVCapture" -framework SwiftUI -framework AppKit -framework AVFoundation
codesign --force --sign - "$app/Contents/MacOS/tapecap"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
