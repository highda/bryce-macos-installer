#!/bin/zsh
# ==============================================================================
#  make-bryce-app.zsh  -  build a standalone "Bryce 3D.app" from YOUR own CD
# ==============================================================================
#
#  Turns your own copy of MetaCreations Bryce 3D (1997, Windows edition)
#  into a standalone macOS app for Apple Silicon:
#
#      Bryce 3D.app
#        Contents/MacOS/bryce3d          launcher
#        Contents/Resources/wine/        bundled Wine engine (WoW64, x86_64)
#        Contents/Resources/prefix/      ready Wine prefix: Bryce installed,
#                                        registered with your serial, CD extras on D:
#
#  The finished app needs no Homebrew, Docker or Wine install. It runs through
#  Rosetta 2. This script needs nothing beyond a stock macOS either (no Xcode).
#  "Bryce 3D Installer.app" is a drag-and-drop front end for this script.
#
#  The extraction method comes from BryceDock (github.com/RaymonDev/BryceDock):
#  data.1 is unpacked directly, so the 16-bit SETUP.EXE never runs.
#
#  USAGE
#      zsh make-bryce-app.zsh SOURCE [options]
#
#      SOURCE is your Bryce 3D CD as an .iso image, another disk image macOS
#      can open (.cdr, .dmg, .toast), the mounted CD itself, or a folder
#      with a copy of the CD.
#
#  OPTIONS
#      --out DIR            where to put "Bryce 3D.app". Default: where it is
#                           already installed, else /Applications, else ~/Applications
#      --serial SERIAL      copied to the clipboard for the registration dialog
#                           (or set BRYCE_SERIAL in the environment)
#      --wine-tarball FILE  use a local Gcenx wine *-osx64.tar.xz instead of downloading
#      --wine-flavor NAME   devel | staging | stable                (default: devel)
#      --icon FILE.icns     app icon (optional)
#      --progress FILE      append machine-readable progress events (for the installer app)
#      --keep-work          keep the temporary build folder for debugging
#
#  REQUIREMENTS (build time only)
#      macOS 14+ (Apple Silicon with Rosetta 2, or Intel), an internet
#      connection (the Wine engine is downloaded), ~3 GB free space.
#
#  LEGAL
#      Nothing from Bryce is downloaded or redistributed. The app built here
#      contains YOUR licensed copy and YOUR registration: do not share it.
#      Share this script (or the installer app) instead.
# ==============================================================================

emulate -L zsh
setopt err_exit pipe_fail no_unset
SELF="${0:A}"

# ---------- defaults ----------------------------------------------------------
APP_NAME="Bryce 3D"
BUNDLE_ID="local.bryce3d.wine"
OUT_DIR=""
WINE_TARBALL=""
WINE_FLAVOR="devel"
SERIAL="${BRYCE_SERIAL:-}"
ICON=""
PROGRESS=""
KEEP_WORK=0
SRC=""
STEPS=8
STEP_N=0

WINE_RELEASES_API="https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases"

# ---------- helpers -----------------------------------------------------------
if [[ -t 1 ]]; then c_bold=$'\e[1m'; c_red=$'\e[31m'; c_grn=$'\e[32m'; c_off=$'\e[0m'
else c_bold=""; c_red=""; c_grn=""; c_off=""; fi
event() { [[ -z "$PROGRESS" ]] || print -r -- "$*" >> "$PROGRESS"; }
log()   { print -r -- "${c_bold}==>${c_off} $*"; }
step()  { (( ++STEP_N )); log "$*"; event "STEP $STEP_N/$STEPS $*"; }
info()  { print -r -- "    $*"; event "INFO $*"; }
ok()    { print -r -- "${c_grn}  ✓${c_off} $*"; }
die()   { print -r -- "${c_red}error:${c_off} $*" >&2; event "ERROR ${*//$'\n'/ }"; exit 1; }

# Print the header comment. (Inside a function $0 is the function's name, so
# use the script path saved at the top level.)
usage() {
  awk 'NR > 3 && !/^#/ { exit } NR > 3 && !/^# =+$/ { sub(/^#[ ]?[ ]?/, ""); print }' "$SELF"
  exit "${1:-0}"
}

# ---------- arguments ---------------------------------------------------------
while (( $# )); do
  case "$1" in
    -h|--help)       usage 0 ;;
    --out)           OUT_DIR="${2:?}"; shift 2 ;;
    --wine-tarball)  WINE_TARBALL="${2:?}"; shift 2 ;;
    --wine-flavor)   WINE_FLAVOR="${2:?}"; shift 2 ;;
    --serial)        SERIAL="${2:?}"; shift 2 ;;
    --icon)          ICON="${2:?}"; shift 2 ;;
    --progress)      PROGRESS="${2:?}"; shift 2 ;;
    --keep-work)     KEEP_WORK=1; shift ;;
    -*)              die "unknown option: $1 (see --help)" ;;
    *)               [[ -z "$SRC" ]] || die "only one CD source, please"; SRC="$1"; shift ;;
  esac
done

[[ -n "$SRC" ]] || usage 1
[[ -e "$SRC" ]] || die "not found: $SRC"
SRC="${SRC:A}"
[[ -z "$WINE_TARBALL" ]] || { [[ -f "$WINE_TARBALL" ]] || die "not found: $WINE_TARBALL"; WINE_TARBALL="${WINE_TARBALL:A}"; }
[[ -z "$ICON" ]] || { [[ -f "$ICON" ]] || die "icon not found: $ICON"; ICON="${ICON:A}"; }

if [[ -z "$OUT_DIR" ]]; then
  if   [[ -d "/Applications/$APP_NAME.app" ]];      then OUT_DIR="/Applications"
  elif [[ -d "$HOME/Applications/$APP_NAME.app" ]]; then OUT_DIR="$HOME/Applications"
  elif [[ -w /Applications ]];                      then OUT_DIR="/Applications"
  else OUT_DIR="$HOME/Applications"; fi
fi

# ---------- 1. preflight ------------------------------------------------------
step "Checking this Mac"
[[ "$(uname -s)" == Darwin ]] || die "this recipe builds a macOS app; run it on a Mac"
if [[ "$(uname -m)" == arm64 ]]; then
  /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null || die "Rosetta 2 is not installed. Install it with:
       softwareupdate --install-rosetta --agree-to-license"
  ok "Apple Silicon with Rosetta 2"
fi
for t in curl tar ditto plutil osascript hdiutil codesign; do
  command -v "$t" >/dev/null || die "missing system tool: $t"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/bryceapp.XXXXXX")"
cleanup() {
  [[ -n "${WINESERVER:-}" && -x "${WINESERVER:-}" ]] && WINEPREFIX="${PREFIX:-/nonexistent}" "$WINESERVER" -k 2>/dev/null || true
  if (( KEEP_WORK )); then print "work folder kept: $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

free_kb=$(df -Pk "$WORK" | awk 'NR==2 {print $4}')
(( free_kb > 3000000 )) || die "not enough free disk space: about 3 GB is needed, $(( free_kb / 1024 )) MB is free"
ok "macOS $(sw_vers -productVersion), $(( free_kb / 1048576 )) GB free"

APP="$WORK/$APP_NAME.app"
RES="$APP/Contents/Resources"
PREFIX="$RES/prefix"
mkdir -p "$APP/Contents/MacOS" "$RES"

# ---------- 2. read the CD ----------------------------------------------------
step "Reading your Bryce 3D CD"
# Sources: a folder or mounted CD, an image bsdtar reads directly (ISO, raw
# .cdr/.toast), or any other disk image (e.g. compressed .dmg), which hdiutil
# first converts to a raw CD image. Nothing gets mounted (macOS 27 refuses to
# attach these ISO9660 images anyway: "no mountable file systems").
SRC_DIR=""
find_data1() { { tar -tf "$1" 2>/dev/null || true; } | grep -i -m1 -E '^(\./)?([^/]*/)?data\.1$'; }
if [[ -d "$SRC" ]]; then
  SRC_DIR="$SRC"
elif ! DATA1="$(find_data1 "$SRC")"; then
  info "converting the disk image"
  hdiutil convert "$SRC" -format UDTO -o "$WORK/cd.cdr" -quiet >/dev/null 2>&1 \
    || die "macOS can't read this file as a CD image: ${SRC:t}"
  SRC="$WORK/cd.cdr"
  DATA1="$(find_data1 "$SRC")" || die "this is not the Bryce 3D Windows CD (no data.1 found)"
fi

mkdir -p "$WORK/unpacked"
if [[ -n "$SRC_DIR" ]]; then
  data1_path="$(find "$SRC_DIR" -maxdepth 2 -iname data.1 -type f | head -n1)"
  [[ -n "$data1_path" ]] || die "this is not the Bryce 3D Windows CD (no data.1 found in ${SRC:t})"
  DATA1="${data1_path#$SRC_DIR/}"
else
  mkdir -p "$WORK/iso"
  tar -xf "$SRC" -C "$WORK/iso" "$DATA1"
  data1_path="$WORK/iso/$DATA1"
fi

# data.1 is an InstallShield v3 archive. The extractor below runs in macOS's own
# JavaScript engine (osascript) and is an ALTERED version (JavaScript port) of:
#
#   unshieldv3 (ISArchiveV3.cpp), Copyright (c) 2019 Wolfgang Frisch.
#   Licensed under the Apache License, Version 2.0; see
#   licenses/unshieldv3-Apache-2.0.txt and THIRD_PARTY_NOTICES.md.
#   Changes: ported from C++ to JavaScript, reads the archive into memory,
#   rejects '.'/'..' path segments.
#
#   blast.c / blast.h version 1.3, Copyright (C) 2003, 2012, 2013 Mark Adler.
#   Changes: ported from C to JavaScript, output to a growing buffer.
#   This software is provided 'as-is', without any express or implied
#   warranty.  In no event will the author be held liable for any damages
#   arising from the use of this software.
#   Permission is granted to anyone to use this software for any purpose,
#   including commercial applications, and to alter it and redistribute it
#   freely, subject to the following restrictions:
#   1. The origin of this software must not be misrepresented; you must not
#      claim that you wrote the original software. If you use this software
#      in a product, an acknowledgment in the product documentation would be
#      appreciated but is not required.
#   2. Altered source versions must be plainly marked as such, and must not be
#      misrepresented as being the original software.
#   3. This notice may not be removed or altered from any source distribution.
#   Mark Adler    madler@alumni.caltech.edu
cat > "$WORK/unshield.js" <<'UNSHIELD_JS'
ObjC.import('Foundation');
const MAXBITS = 13;
function construct(rep) {
  const length = [];
  for (const b of rep) { let left = (b >> 4) + 1; const len = b & 15; while (left--) length.push(len); }
  const count = new Int16Array(MAXBITS + 1);
  for (const l of length) count[l]++;
  const offs = new Int16Array(MAXBITS + 1);
  for (let len = 1; len < MAXBITS; len++) offs[len + 1] = offs[len] + count[len];
  const symbol = new Int16Array(length.length);
  for (let s = 0; s < length.length; s++) if (length[s]) symbol[offs[length[s]]++] = s;
  return { count, symbol };
}
const LITCODE = construct([
  11, 124, 8, 7, 28, 7, 188, 13, 76, 4, 10, 8, 12, 10, 12, 10, 8, 23, 8,
  9, 7, 6, 7, 8, 7, 6, 55, 8, 23, 24, 12, 11, 7, 9, 11, 12, 6, 7, 22, 5,
  7, 24, 6, 11, 9, 6, 7, 22, 7, 11, 38, 7, 9, 8, 25, 11, 8, 11, 9, 12,
  8, 12, 5, 38, 5, 38, 5, 11, 7, 5, 6, 21, 6, 10, 53, 8, 7, 24, 10, 27,
  44, 253, 253, 253, 252, 252, 252, 13, 12, 45, 12, 45, 12, 61, 12, 45,
  44, 173]);
const LENCODE = construct([2, 35, 36, 53, 38, 23]);
const DISTCODE = construct([2, 20, 53, 230, 247, 151, 248]);
const BASE = [3, 2, 4, 5, 6, 7, 8, 9, 10, 12, 16, 24, 40, 72, 136, 264];
const EXTRA = [0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8];
function blast(inp, expected) {
  let pos = 0, bitbuf = 0, bitcnt = 0;
  const eof = () => { throw new Error('compressed data ends early'); };
  function bits(need) {
    let val = bitbuf;
    while (bitcnt < need) { if (pos >= inp.length) eof(); val |= inp[pos++] << bitcnt; bitcnt += 8; }
    bitbuf = val >> need; bitcnt -= need;
    return val & ((1 << need) - 1);
  }
  function decode(h) {
    let bb = bitbuf, left = bitcnt, code = 0, first = 0, index = 0, len = 1, next = 1;
    for (;;) {
      while (left--) {
        code |= (bb & 1) ^ 1; bb >>= 1;
        const count = h.count[next++];
        if (code < first + count) {
          bitbuf = bb; bitcnt = (bitcnt - len) & 7;
          return h.symbol[index + (code - first)];
        }
        index += count; first += count; first <<= 1; code <<= 1; len++;
      }
      left = (MAXBITS + 1) - len;
      if (left === 0) break;
      if (pos >= inp.length) eof();
      bb = inp[pos++];
      if (left > 8) left = 8;
    }
    throw new Error('invalid Huffman code');
  }
  const lit = bits(8);
  if (lit > 1) throw new Error('invalid literal flag');
  const dict = bits(8);
  if (dict < 4 || dict > 6) throw new Error('invalid dictionary size');
  let out = new Uint8Array(Math.max(expected, 4096)), n = 0;
  const ensure = (k) => { if (n + k > out.length) { const o = new Uint8Array(Math.max(out.length * 2, n + k)); o.set(out); out = o; } };
  for (;;) {
    if (bits(1)) {
      const sym = decode(LENCODE);
      let len = BASE[sym] + bits(EXTRA[sym]);
      if (len === 519) break;
      const sh = len === 2 ? 2 : dict;
      const dist = (decode(DISTCODE) << sh) + bits(sh) + 1;
      if (dist > n) throw new Error('distance too far back');
      ensure(len);
      while (len--) { out[n] = out[n - dist]; n++; }
    } else {
      ensure(1);
      out[n++] = lit ? decode(LITCODE) : bits(8);
    }
  }
  return out.subarray(0, n);
}
// File I/O through Foundation: Latin-1 maps bytes 0-255 to characters 1:1.
function readBytes(path) {
  const d = $.NSData.dataWithContentsOfFile(path);
  if (d.isNil()) throw new Error('cannot read ' + path);
  const s = $.NSString.alloc.initWithDataEncoding(d, $.NSISOLatin1StringEncoding).js;
  const b = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) b[i] = s.charCodeAt(i);
  return b;
}
function writeBytes(path, bytes) {
  const parts = [];
  for (let i = 0; i < bytes.length; i += 0x8000) parts.push(String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000)));
  const d = $(parts.join('')).dataUsingEncoding($.NSISOLatin1StringEncoding);
  if (!d.writeToFileAtomically(path, true)) throw new Error('cannot write ' + path);
}
function run(argv) {
  const [archive, dest] = argv;
  const buf = readBytes(archive);
  const dv = new DataView(buf.buffer);
  const u8 = (p) => dv.getUint8(p), u16 = (p) => dv.getUint16(p, true), u32 = (p) => dv.getUint32(p, true);
  const str = (p, n) => String.fromCharCode.apply(null, buf.subarray(p, p + n));
  if (buf.length < 59 || u32(0) !== 0x8C655D13 || u32(4) !== 0x02013a) throw new Error('not an InstallShield v3 archive');
  if (u8(30) > 1) throw new Error('multi-volume archives are not supported');
  let p = u32(41);
  const dirs = [];
  for (let i = u16(49); i > 0; i--) { dirs.push({ files: u16(p), name: str(p + 6, u16(p + 4)) }); p += u16(p + 2); }
  const files = [];
  for (const d of dirs) for (let i = 0; i < d.files; i++) {
    const name = str(p + 30, u8(p + 29));
    files.push({ usize: u32(p + 3), csize: u32(p + 7), offset: u32(p + 11), attrib: u8(p + 25),
                 path: (d.name ? d.name + '\\' + name : name).split('\\').filter((s) => s.length) });
    p += u16(p + 23);
  }
  const fm = $.NSFileManager.defaultManager;
  for (const f of files) {
    if (!f.path.length || f.path.some((s) => s === '.' || s === '..' || s.includes('/'))) throw new Error('unsafe path: ' + f.path.join('\\'));
    const raw = buf.subarray(f.offset, f.offset + f.csize);
    const data = (f.attrib & 0x10) ? raw : blast(raw, f.usize);
    if (data.length !== f.usize) throw new Error('size mismatch: ' + f.path.join('\\'));
    const out = dest + '/' + f.path.join('/');
    fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(out.slice(0, out.lastIndexOf('/')), true, $(), null);
    writeBytes(out, data);
  }
  return files.length + ' files extracted';
}
UNSHIELD_JS
/usr/bin/osascript -l JavaScript "$WORK/unshield.js" "$data1_path" "$WORK/unpacked" >/dev/null \
  || die "could not unpack data.1 from your CD. Is the image complete?"
PROG_DIR="$(find "$WORK/unpacked" -maxdepth 2 -type d -iname prog | head -n1)"
[[ -n "$PROG_DIR" && -f "$PROG_DIR/Bryce 3D.exe" ]] || die "'Bryce 3D.exe' not found on this CD"
ok "Bryce 3D program files extracted"

# ---------- 3. Wine engine ---------------------------------------------------
step "Downloading the Wine engine (about 200 MB)"
if [[ -z "$WINE_TARBALL" ]]; then
  url="$(curl -fsSL "$WINE_RELEASES_API" 2>/dev/null \
        | grep -oE "https://[^\"]*/wine-${WINE_FLAVOR}-[0-9][0-9._]*-osx64\.tar\.xz" \
        | head -n1 || true)"
  [[ -n "$url" ]] || die "could not reach GitHub to download Wine. Check your internet connection.
       (Or download wine-${WINE_FLAVOR}-*-osx64.tar.xz from https://github.com/Gcenx/macOS_Wine_builds/releases
       and pass it with --wine-tarball FILE)"
  info "${url:t}"
  WINE_TARBALL="$WORK/${url:t}"
  curl -fL --retry 3 --progress-bar "$url" -o "$WINE_TARBALL" || die "the Wine download failed. Check your internet connection and try again."
fi
mkdir -p "$WORK/wine-dl"
tar -xJf "$WINE_TARBALL" -C "$WORK/wine-dl" || die "the Wine download is damaged. Try again."
WINE_ROOT="$(find "$WORK/wine-dl" -type d -path '*/Contents/Resources/wine' | head -n1)"
[[ -n "$WINE_ROOT" ]] || die "unexpected Wine package layout (no */Contents/Resources/wine)"
ditto "$WINE_ROOT" "$RES/wine"
rm -rf "$WORK/wine-dl"
[[ "$WINE_TARBALL" == "$WORK/"* ]] && rm -f "$WINE_TARBALL"
xattr -cr "$RES/wine" 2>/dev/null || true

WINE="$RES/wine/bin/wine"
[[ -x "$WINE" ]] || WINE="$RES/wine/bin/wine64"
[[ -x "$WINE" ]] || die "no wine binary inside the Wine package"
WINESERVER="$RES/wine/bin/wineserver"
ok "Wine $("$WINE" --version 2>/dev/null || print '?') bundled"

# ---------- 4. Wine prefix ---------------------------------------------------
step "Preparing Windows (takes a minute)"
export WINEPREFIX="$PREFIX"
export WINEDEBUG=-all
# Skip the Mono/Gecko install prompts and the Finder/Dock menu-entry builder.
export WINEDLLOVERRIDES="mscoree=;mshtml=;winemenubuilder.exe=d"
"$WINE" wineboot --init >/dev/null 2>&1 || true
"$WINESERVER" -w
[[ -d "$PREFIX/drive_c/windows/syswow64" ]] || die "this Wine build has no 32-bit (WoW64) support.
       Try --wine-flavor staging, or another release via --wine-tarball"
ok "WoW64 prefix ready (32-bit apps supported)"

# Bryce -> C:\Bryce3D
ditto "$PROG_DIR" "$PREFIX/drive_c/Bryce3D"
chmod -R u+rwX "$PREFIX/drive_c/Bryce3D"

# ---------- 5. CD extras -> D: ------------------------------------------------
step "Copying the CD's libraries and sample scenes"
mkdir -p "$PREFIX/bryce_cd"
cd_excludes=(
  --exclude "$DATA1"
  --exclude 'Adobe Acrobat Reader 3*' --exclude 'DirectX5*' --exclude 'OpenGL*'
  --exclude 'QuickTime Installer.EXE' --exclude 'SETUP.EXE' --exclude 'SETUP.INS'
  --exclude '_INST32I.EX_' --exclude '_ISDEL.EXE' --exclude '_SETUP.DLL'
  --exclude '_SETUP.LIB' --exclude 'setup.bmp' --exclude 'setup.ini' --exclude 'setup.pkg'
)
if [[ -n "$SRC_DIR" ]]; then
  tar -cf - -C "$SRC_DIR" "${cd_excludes[@]}" . 2>/dev/null | tar -xf - -C "$PREFIX/bryce_cd" 2>/dev/null || true
else
  tar -xf "$SRC" -C "$PREFIX/bryce_cd" "${cd_excludes[@]}" 2>/dev/null || true
fi
chmod -R u+rwX "$PREFIX/bryce_cd" 2>/dev/null || true
# Relative links, so the prefix still works after it is copied elsewhere.
ln -sfn ../bryce_cd "$PREFIX/dosdevices/d:"
ln -sfn ../../bryce_cd "$PREFIX/drive_c/Bryce3D/CD_Content"
ok "CD content on D:"

# ---------- 6. registry -------------------------------------------------------
step "Configuring Bryce"
cat > "$WORK/bryce.reg" <<'EOF'
REGEDIT4

[HKEY_CURRENT_USER\Software\Wine]
"Version"="winxp"

[HKEY_CURRENT_USER\Software\Wine\Mac Driver]
"RetinaMode"="n"

[HKEY_LOCAL_MACHINE\Software\Wine\Drives]
"d:"="cdrom"

[HKEY_CLASSES_ROOT\.br3]
@="Bryce3Dfile"

[HKEY_CLASSES_ROOT\Bryce3Dfile]
@="Bryce 3D Scene"

[HKEY_CLASSES_ROOT\Bryce3Dfile\Shell\open\command]
@="\"C:\\Bryce3D\\Bryce 3D.exe\" \"%1\""
EOF
"$WINE" regedit "$WORK/bryce.reg" >/dev/null 2>&1
"$WINESERVER" -w
# winxp, not win98: in win98 mode Bryce takes a Windows 9x code path that
# needs LDT segments, which Rosetta does not support ("rosetta error: LDT ...
# not supported", Bryce then spins at 100% CPU with no window).
ok "registry configured (Windows XP mode)"

# ---------- 7. one-time registration (your serial) ----------------------------
# Bryce writes MetaImage.dll into its folder once personalised (BryceDock uses
# the same marker). Doing this now bakes the registration into the app.
step "Registering Bryce 3D"
if [[ ! -f "$PREFIX/drive_c/Bryce3D/MetaImage.dll" ]]; then
  if [[ -n "$SERIAL" ]]; then
    print -rn -- "$SERIAL" | pbcopy
    print "    Your serial is on the clipboard: paste it with ⌘V."
  fi
  print "    Bryce will open with its personalization dialog."
  print "    Enter your name, organisation and serial, then click OK."
  print "    This continues by itself once registration is saved."
  print "    If no dialog shows up, click the Wine icon in the Dock (it can open behind other windows)."
  event "REGISTER"
  ( cd "$PREFIX/drive_c/Bryce3D" && "$WINE" 'C:\Bryce3D\Bryce 3D.exe' >/dev/null 2>&1 ) &
  bryce_pid=$!
  # Bring Wine to the front once its window exists (no Accessibility permission needed).
  ( for i in {1..30}; do
      sleep 1
      /usr/bin/osascript -l JavaScript -e '
        ObjC.import("AppKit");
        var apps = $.NSWorkspace.sharedWorkspace.runningApplications, hit = false;
        for (var i = 0; i < apps.count; i++) {
          var a = apps.objectAtIndex(i);
          if (a.localizedName.js === "wine" && a.activationPolicy === 0) {
            a.activateWithOptions($.NSApplicationActivateAllWindows); hit = true;
          }
        }
        hit;' 2>/dev/null | grep -q true && break
    done ) &!
  registered=0
  while kill -0 $bryce_pid 2>/dev/null; do
    if [[ -f "$PREFIX/drive_c/Bryce3D/MetaImage.dll" ]]; then registered=1; break; fi
    sleep 1
  done
  [[ -f "$PREFIX/drive_c/Bryce3D/MetaImage.dll" ]] && registered=1
  sleep 2
  "$WINESERVER" -k 2>/dev/null || true
  wait $bryce_pid 2>/dev/null || true
  [[ -n "$SERIAL" ]] && print -n "" | pbcopy
  (( registered )) || die "Bryce was closed before the registration was saved. Please run the installer again."
fi
ok "registered"
"$WINESERVER" -w 2>/dev/null || true

# Leave the prefix clean.
rm -rf "$PREFIX/drive_c/users/$USER/Temp/"* 2>/dev/null || true
date +%s > "$PREFIX/.bryce_build_id"

# ---------- 8. app bundle -----------------------------------------------------
step "Installing Bryce 3D.app"
cat > "$APP/Contents/MacOS/bryce3d" <<'LAUNCHER'
#!/bin/zsh
# Bryce 3D.app launcher. The bundle stays read-only (codesign, App Translocation),
# so the prefix template is copied to Application Support on first launch
# and whenever the app is rebuilt. The app works from any folder.
emulate -L zsh
RES="${0:A:h:h}/Resources"
SUPPORT="$HOME/Library/Application Support/Bryce 3D"
export WINEPREFIX="$SUPPORT/prefix"
export WINEDEBUG=-all
export WINEDLLOVERRIDES="mscoree=;mshtml=;winemenubuilder.exe=d"
WINE="$RES/wine/bin/wine"; [[ -x "$WINE" ]] || WINE="$RES/wine/bin/wine64"

alert() {
  /usr/bin/osascript -e "display alert \"Bryce 3D\" message \"$1\" as critical" >/dev/null 2>&1
}

if [[ "$(uname -m)" == arm64 ]] && ! /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
  alert "Rosetta 2 is required. Open Terminal and run: softwareupdate --install-rosetta --agree-to-license"
  exit 1
fi

if [[ ! -f "$WINEPREFIX/.bryce_build_id" ]] || \
   ! cmp -s "$RES/prefix/.bryce_build_id" "$WINEPREFIX/.bryce_build_id"; then
  mkdir -p "$SUPPORT"
  if [[ -d "$WINEPREFIX" ]]; then
    mv "$WINEPREFIX" "$SUPPORT/prefix.old-$(date +%Y%m%d-%H%M%S)"
  fi
  /usr/bin/ditto "$RES/prefix" "$WINEPREFIX" || { alert "Could not set up $WINEPREFIX"; exit 1; }
fi

# Scenes and renders: C:\Bryce3D\Projects and E: both point to ~/Documents/Bryce 3D
PROJ="$HOME/Documents/Bryce 3D"
mkdir -p "$PROJ"
ln -sfn "$PROJ" "$WINEPREFIX/drive_c/Bryce3D/Projects"
ln -sfn "$PROJ" "$WINEPREFIX/dosdevices/e:"

# Bryce's interface is a fixed 640x480 panel. Wine scales DPI-unaware apps by
# the Windows DPI, so pick the largest scale (in 0.25 steps) that fits the main
# screen. Override with:  defaults write local.bryce3d.wine Scale 1.5   (1 = off)
SCALE="$(/usr/bin/defaults read local.bryce3d.wine Scale 2>/dev/null || true)"
if [[ -z "$SCALE" ]]; then
  SCALE="$(/usr/bin/osascript -l JavaScript -e '
    ObjC.import("AppKit");
    var f = $.NSScreen.mainScreen.visibleFrame.size;
    Math.max(1, Math.floor(Math.min(f.width / 640, f.height / 480) * 4) / 4);
  ' 2>/dev/null || print 1)"
fi
[[ "$SCALE" == <->(.<->|) ]] || SCALE=1
DPI="$(printf '%.0f' $(( 96.0 * SCALE )))"
(( DPI >= 96 && DPI <= 480 )) || DPI=96
"$WINE" reg add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d $DPI /f >/dev/null 2>&1

cd "$WINEPREFIX/drive_c/Bryce3D" || exit 1
exec "$WINE" 'C:\Bryce3D\Bryce 3D.exe' "$@" >"$SUPPORT/last-run.log" 2>&1
LAUNCHER
chmod +x "$APP/Contents/MacOS/bryce3d"

ICON_KEY=""
if [[ -n "$ICON" ]]; then
  cp "$ICON" "$RES/AppIcon.icns"
  ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>bryce3d</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>$(cat "$PREFIX/.bryce_build_id")</string>
  <key>CFBundleShortVersionString</key><string>3.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
  <key>NSHighResolutionCapable</key><false/>
  $ICON_KEY
</dict>
</plist>
EOF
plutil -lint "$APP/Contents/Info.plist" >/dev/null || die "Info.plist is invalid"

# Local ad-hoc signature for the bundle. Wine's own binaries keep their signatures.
codesign --force --sign - "$APP" >/dev/null 2>&1 || print "    (ad-hoc signing skipped)"

mkdir -p "$OUT_DIR" 2>/dev/null || die "cannot create $OUT_DIR"
[[ -w "$OUT_DIR" ]] || die "no permission to write to $OUT_DIR. Use --out ~/Applications"
DEST="$OUT_DIR/$APP_NAME.app"
if [[ -e "$DEST" ]]; then
  pkill -f "$DEST/Contents/" 2>/dev/null || true
  mv "$DEST" "$WORK/previous.app"
  info "previous version replaced"
fi
ditto "$APP" "$DEST"
size="$(du -sh "$DEST" | cut -f1)"
ok "installed: $DEST ($size)"
event "DONE $DEST"

print
log "${c_grn}Done:${c_off} $DEST ($size)"
print "    Scenes and renders go to ~/Documents/Bryce 3D (also C:\\Bryce3D\\Projects and E:)."
print "    The CD's libraries and samples are on D:."
print "    This app contains your licensed copy and registration. Please don't share it."
