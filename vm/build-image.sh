#!/bin/bash
# Builds the Bryce 3D runtime VM: out/Image (kernel), out/initrd, out/root.img (ext4).
# Needs Docker (development machine or CI); end users never need Docker.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/out}"
mkdir -p "$OUT"

docker build --platform linux/arm64 -f "$HERE/rootfs.Dockerfile" -t bryce-vm-rootfs "$HERE"

cid=$(docker create --platform linux/arm64 bryce-vm-rootfs)
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
rm -f "$OUT/root.img" "$OUT/Image"

# Stream the filesystem into a container that unpacks it as root (keeps owners,
# modes and device nodes) and builds the ext4 image with mkfs.ext4 -d. No
# intermediate tar file on the host.
docker export "$cid" | docker run -i --rm --platform linux/arm64 -v "$OUT":/out -v "$HERE":/src:ro ubuntu:24.04 bash -euc '
  mkdir /r && tar -xpf - -C /r
  apt-get update -qq >/dev/null && apt-get install -y -qq e2fsprogs >/dev/null
  rm -f /r/.dockerenv
  kver=$(ls /r/lib/modules | head -n1)
  echo "kernel $kver"
  ls /r/lib/modules/$kver/kernel/drivers/gpu/drm/virtio/ 2>/dev/null || echo "WARNING: no virtio-gpu module"
  zcat /r/boot/vmlinuz-$kver > /out/Image 2>/dev/null || cp /r/boot/vmlinuz-$kver /out/Image
  [ -f /r/boot/initrd.img-$kver ] && cp /r/boot/initrd.img-$kver /out/initrd || echo "no initrd (not needed: virtio-blk and ext4 are built in)"
  bash /src/make-manifest.sh /r /out      # packages.tsv + SOURCES.md (licenses)
  size=$(( $(du -sm /r | cut -f1) * 108 / 100 + 64 ))
  rm -f /out/root.img
  mkfs.ext4 -q -L bryce-root -d /r /out/root.img ${size}M
  echo "root.img ${size} MB"
'
ls -lh "$OUT"
