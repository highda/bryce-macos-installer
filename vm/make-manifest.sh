#!/bin/bash
# Lists what the runtime image contains, for license compliance:
#   OUT/packages.tsv   package, version, source package, source version
#   OUT/SOURCES.md     where the source code of every component is, and the written offer
# Usage (inside the build container): make-manifest.sh ROOTFS OUT
set -euo pipefail
ROOT="$1"; OUT="$2"

dpkg-query --admindir="$ROOT/var/lib/dpkg" -W \
  -f='${binary:Package}\t${Version}\t${source:Package}\t${source:Version}\n' | sort > "$OUT/packages.tsv"

{
cat <<'HEAD'
# Sources of the Bryce runtime (Linux VM image)

Bryce.app contains a small Linux system, built by `vm/build-image.sh` from
`vm/rootfs.Dockerfile` in https://github.com/highda/bryce-macos-installer.
Inside the image, every package keeps its license in `/usr/share/doc/<package>/copyright`.

## Written offer

For at least three years after each release, the complete corresponding source code of
every program in the image that is licensed under the GPL or LGPL is available on request:
open an issue at https://github.com/highda/bryce-macos-installer/issues.
Most of it can also be downloaded directly from the links below.

## Components not from Ubuntu

| Component | Version | Source | License |
|---|---|---|---|
HEAD
awk -F'\t' '/^hangover-/ { v = $2; sub(/~.*/, "", v); rel = "https://github.com/AndreRH/hangover/releases/tag/hangover-" v
  if ($1 ~ /wowbox64/)  printf "| %s | %s | %s (Box64: https://github.com/ptitSeb/box64) | MIT |\n", $1, $2, rel
  else if ($1 ~ /fex/)  printf "| %s | %s | %s (FEX: https://github.com/FEX-Emu/FEX) | MIT |\n", $1, $2, rel
  else                  printf "| %s | %s | %s (Wine: https://gitlab.winehq.org/wine/wine) | LGPL-2.1-or-later |\n", $1, $2, rel }' "$OUT/packages.tsv"
cat <<'MID'
| unshieldv3 | 4e5700fb | https://github.com/wfr/unshieldv3/tree/4e5700fb97ba9f0338b49c1031834ce42177f265 | Apache-2.0 |
| Bryce guest scripts (`bryce-*`) | this release | `vm/guest/` in this repository | MIT |

## Ubuntu 24.04 packages

Source code: `https://launchpad.net/ubuntu/+source/SOURCE/VERSION`, or
`apt-get source SOURCE=VERSION` on Ubuntu 24.04.

| Source package | Version | Binary packages |
|---|---|---|
MID
awk -F'\t' '!/^hangover-/ { k = $3 "\t" $4; bins[k] = (k in bins ? bins[k] ", " : "") $1 }
  END { for (k in bins) { split(k, a, "\t")
    printf "| [%s](https://launchpad.net/ubuntu/+source/%s/%s) | %s | %s |\n", a[1], a[1], a[2], a[2], bins[k] } }' \
  "$OUT/packages.tsv" | sort
} > "$OUT/SOURCES.md"
echo "$(wc -l < "$OUT/packages.tsv") packages listed in packages.tsv and SOURCES.md"
