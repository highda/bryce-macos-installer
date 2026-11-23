#!/bin/zsh
# Builds "Bryce 3D Installer.app" and "Bryce 3D Installer.dmg" (for sharing) from
#   installer/Bryce 3D Installer.applescript   the drag-and-drop front end
#   make-bryce-app.zsh                         the build engine (bundled inside)
#
# Usage:  zsh build-installer.zsh [--out DIR] [--sign "Developer ID Application: ..."]
#
# Uses only tools that ship with macOS (osacompile, plutil, codesign, ditto, hdiutil).
# Without a Developer ID the app is signed ad hoc, and people who download it
# have to allow it once in System Settings › Privacy & Security ("Open Anyway").

emulate -L zsh
setopt err_exit pipe_fail no_unset

HERE="${0:A:h}"
OUT="$HERE/dist"
IDENTITY="-"
while (( $# )); do
  case "$1" in
    --out)  OUT="${2:?}"; shift 2 ;;
    --sign) IDENTITY="${2:?}"; shift 2 ;;
    *) print -u2 "unknown option: $1"; exit 1 ;;
  esac
done

APP="$OUT/Bryce 3D Installer.app"
rm -rf "$APP"
mkdir -p "$OUT"

osacompile -o "$APP" "$HERE/installer/Bryce 3D Installer.applescript"
cp "$HERE/make-bryce-app.zsh" "$APP/Contents/Resources/make-bryce-app.zsh"

PL="$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "local.bryce3d.installer" "$PL"
plutil -replace CFBundleName -string "Bryce 3D Installer" "$PL"
plutil -replace CFBundleShortVersionString -string "1.0" "$PL"
plutil -replace LSMinimumSystemVersion -string "14.0" "$PL"
# Accept dropped disk images, CD volumes and folders.
plutil -replace CFBundleDocumentTypes -json '[
  {"CFBundleTypeName":"Bryce 3D CD","CFBundleTypeRole":"Viewer","LSHandlerRank":"None",
   "LSItemContentTypes":["public.iso-image","public.disk-image","public.folder","public.volume","public.data"]}
]' "$PL"
plutil -lint "$PL" >/dev/null

if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - "$APP"
else
  codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi

# A disk image is what gets published: one file to download, and the installer
# runs straight from the mounted disk (no unzipping, no copying).
DMG="$OUT/Bryce 3D Installer.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Bryce 3D Installer.app"
rm -f "$DMG"
hdiutil create -quiet -volname "Bryce 3D Installer" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG" 2>/dev/null
[[ "$IDENTITY" == "-" ]] || codesign --force --timestamp --sign "$IDENTITY" "$DMG"
print "built: $APP"
print "dmg:   $DMG"
