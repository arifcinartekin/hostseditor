#!/bin/zsh
# Builds "Hosts Editor.app" into ./build. Pass --install to copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Hosts Editor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal binary (Apple Silicon + Intel). Override with ARCHS="arm64" for a faster local build.
BINS=()
for arch in ${=ARCHS:-arm64 x86_64}; do
  swiftc -O -parse-as-library -target "$arch-apple-macos14.0" Sources/*.swift -o "build/HostsEditor-$arch"
  BINS+=("build/HostsEditor-$arch")
done
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/HostsEditor"
rm -f "${BINS[@]}"
cp Info.plist "$APP/Contents/Info.plist"

if [[ ! -f build/AppIcon.icns ]]; then
  ICONSET=build/AppIcon.iconset
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  swift Scripts/make-icon.swift build/icon_1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--zip" ]]; then
  rm -f build/HostsEditor.zip
  ditto -c -k --keepParent "$APP" build/HostsEditor.zip
  echo "Packaged build/HostsEditor.zip"
fi

if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/Hosts Editor.app"
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Hosts Editor.app"
fi
