#!/bin/bash
# Assembles "Bryce.app" and "Bryce.dmg" from the host source and a built
# runtime (vm/build-image.sh output: Image + root.img).
#
#   vm/build-app.sh RUNTIME_DIR [OUT_DIR] [--sign "Developer ID Application: ..."]
#
# Needs Xcode Command Line Tools (swiftc). Contains no part of Bryce.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RUNTIME="${1:?usage: build-app.sh RUNTIME_DIR [OUT_DIR] [--sign IDENTITY]}"
OUT="${2:-$HERE/../dist}"
IDENTITY="-"
[[ "${3:-}" == "--sign" ]] && IDENTITY="${4:?}"
VERSION="${BRYCE_VERSION:-2.1.0}"

APP="$OUT/Bryce.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/runtime"

swiftc -O -target arm64-apple-macos14 "$HERE"/host/*.swift -o "$APP/Contents/MacOS/Bryce"
# APFS clones: no extra disk space for the 2 GB system image.
cp -c "$RUNTIME/Image" "$RUNTIME/root.img" "$APP/Contents/Resources/runtime/" 2>/dev/null \
  || cp "$RUNTIME/Image" "$RUNTIME/root.img" "$APP/Contents/Resources/runtime/"

# Licenses: this project's, the third-party notices, and the runtime's package
# list with links to the source code (from vm/build-image.sh).
mkdir -p "$APP/Contents/Resources/Licenses"
cp "$HERE/../LICENSE" "$HERE/../THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/Licenses/"
for f in SOURCES.md packages.tsv; do
  [[ -f "$RUNTIME/$f" ]] && cp "$RUNTIME/$f" "$APP/Contents/Resources/Licenses/"
done

# App icon: original artwork drawn by vm/icon/make-icon.swift (no image files).
ICONSET="$(mktemp -d)/AppIcon.iconset"
swift "$HERE/icon/make-icon.swift" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Bryce</string>
  <key>CFBundleDisplayName</key><string>Bryce</string>
  <key>CFBundleIdentifier</key><string>io.github.highda.bryce3d</string>
  <key>CFBundleExecutable</key><string>Bryce</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Runs your own copy of Bryce 2, Bryce 3D or Bryce 4 for Windows. Bryce is not included.</string>
</dict>
</plist>
EOF
plutil -lint "$APP/Contents/Info.plist" >/dev/null

if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - --entitlements "$HERE/host/entitlements.plist" "$APP"
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    --entitlements "$HERE/host/entitlements.plist" "$APP"
fi
codesign --verify "$APP"

# Disk image: the app plus an Applications link to drag it onto. Built as an
# empty read-write image of a known size, filled, then compressed (-srcfolder
# undersizes the volume because root.img is a sparse file).
DMG="$OUT/Bryce.dmg"
WORKDIR="$(mktemp -d)"
MNT="$WORKDIR/mnt"
trap 'hdiutil detach -quiet "$MNT" 2>/dev/null || true; rm -rf "$WORKDIR"' EXIT
mb=$(( $(du -A -s -k "$APP" | cut -f1) * 11 / 10 / 1024 + 64 ))
hdiutil create -quiet -size ${mb}m -fs HFS+ -volname "Bryce" -type UDIF -layout NONE "$WORKDIR/rw.dmg"
mkdir -p "$MNT"
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$MNT" "$WORKDIR/rw.dmg"
ditto "$APP" "$MNT/Bryce.app"
ln -s /Applications "$MNT/Applications"
hdiutil detach -quiet "$MNT"
rm -f "$DMG"
hdiutil convert -quiet "$WORKDIR/rw.dmg" -format ULFO -o "$DMG"
[[ "$IDENTITY" == "-" ]] || codesign --force --timestamp --sign "$IDENTITY" "$DMG"
ls -lh "$DMG"
du -sh "$APP"
