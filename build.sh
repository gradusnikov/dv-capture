#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
stage=$(mktemp -d "$PWD/build/stage.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/DV Capture.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Licenses"
make -C tapecap -j4 ARCHS='-arch arm64'
cp tapecap/build/tapecap "$app/Contents/MacOS/tapecap"
cp Info.plist "$app/Contents/Info.plist"
iconset="$stage/DVCapture.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" assets/DVCapture.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" assets/DVCapture.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/DVCapture.icns"
MACOSX_DEPLOYMENT_TARGET=13.0 cargo build --manifest-path media/Cargo.toml --release --locked --target aarch64-apple-darwin --target-dir build/cargo
cp build/cargo/aarch64-apple-darwin/release/dv-media "$app/Contents/MacOS/dv-media"
cp -R licenses/rust "$app/Contents/Resources/Licenses/"
cp tapecap/LICENSE "$app/Contents/Resources/Licenses/tapecap.txt"
cp tapecap/third_party/AVCVideoServices/NOTICE.md "$app/Contents/Resources/Licenses/Apple-Provenance.txt"
sed -n '1,45p' tapecap/third_party/AVCVideoServices/DVReceiver.cpp > "$app/Contents/Resources/Licenses/Apple.txt"
./bundle-runtime.sh "$app/Contents/Resources"
mkdir -p build/module-cache
xcrun swiftc -target arm64-apple-macos13.0 -module-cache-path build/module-cache -swift-version 5 -parse-as-library -O DVCapture.swift -o "$app/Contents/MacOS/DVCapture" -framework SwiftUI -framework AppKit -framework AVFoundation
codesign --force --sign - "$app/Contents/MacOS/dv-media"
codesign --force --sign - "$app/Contents/MacOS/tapecap"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
rsync -a --delete "$app/" "build/DV Capture.app/"
codesign --verify --deep --strict "build/DV Capture.app"
