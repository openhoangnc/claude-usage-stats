#!/bin/bash
set -e
# Builds AppIcon.icns from generate_icon.swift.
cd "$(dirname "$0")"

echo "[1/3] Compiling icon renderer..."
swiftc -O generate_icon.swift -o generate_icon_bin

echo "[2/3] Rendering iconset..."
rm -rf AppIcon.iconset
mkdir -p AppIcon.iconset
render() { ./generate_icon_bin "$1" "AppIcon.iconset/$2" >/dev/null; }
render 16   icon_16x16.png
render 32   icon_16x16@2x.png
render 32   icon_32x32.png
render 64   icon_32x32@2x.png
render 128  icon_128x128.png
render 256  icon_128x128@2x.png
render 256  icon_256x256.png
render 512  icon_256x256@2x.png
render 512  icon_512x512.png
render 1024 icon_512x512@2x.png
# Standalone preview PNG for the README.
./generate_icon_bin 512 icon.png >/dev/null

echo "[3/3] Building AppIcon.icns..."
iconutil -c icns AppIcon.iconset -o AppIcon.icns
rm -f generate_icon_bin
echo "Done: AppIcon.icns + icon.png"
