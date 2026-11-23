# Root filesystem of the Bryce 3D runtime VM (Linux ARM64).
# Built with Docker only as a convenient way to assemble files; the result is
# exported and turned into an ext4 disk image by build-image.sh.
# Contains no part of Bryce: that comes from the user's CD on first start.

FROM --platform=linux/arm64 ubuntu:24.04 AS unshield
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential cmake curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*
# Pinned commit: reproducible, and the binary's exact source is known (Apache-2.0).
ARG UNSHIELD_COMMIT=4e5700fb97ba9f0338b49c1031834ce42177f265
RUN curl -fsSL https://codeload.github.com/wfr/unshieldv3/tar.gz/${UNSHIELD_COMMIT} | tar -xz -C /tmp \
 && mv /tmp/unshieldv3-${UNSHIELD_COMMIT} /tmp/unshieldv3-src \
 && mkdir -p /licenses/unshieldv3 && cp /tmp/unshieldv3-src/LICENSE /licenses/unshieldv3/ \
 && cmake -S /tmp/unshieldv3-src -B /tmp/build -DCMAKE_BUILD_TYPE=Release \
 && cmake --build /tmp/build -j"$(nproc)" \
 && install -m 755 /tmp/build/unshieldv3 /usr/local/bin/unshieldv3

FROM --platform=linux/arm64 ubuntu:24.04

ARG HANGOVER_VERSION=11.16
ARG HANGOVER_SHA256=94611dad2b23978d35825a018c81b3947caaec174aa04c052849d37bc6a39e72
ENV DEBIAN_FRONTEND=noninteractive

# Kernel, init, display, window manager, tools.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      linux-image-virtual \
      systemd systemd-sysv udev dbus kmod e2fsprogs util-linux iproute2 \
      xserver-xorg-core xserver-xorg-input-libinput x11-xserver-utils xinit \
      openbox spice-vdagent python3 python3-xlib python3-evdev libarchive-tools fonts-dejavu-core \
      ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

# Hangover: ARM64 Wine with WoW64 + FEX (x86 translator).
RUN curl -fsSL -o /tmp/hangover.tar \
      "https://github.com/AndreRH/hangover/releases/download/hangover-${HANGOVER_VERSION}/hangover_${HANGOVER_VERSION}_ubuntu2404_noble_arm64.tar" \
 && echo "${HANGOVER_SHA256}  /tmp/hangover.tar" | sha256sum -c - \
 && mkdir /tmp/hangover && tar -xf /tmp/hangover.tar -C /tmp/hangover \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      /tmp/hangover/*.deb \
 && rm -rf /tmp/hangover /tmp/hangover.tar /var/lib/apt/lists/*

# Slim down: Wine's binaries ship with debug info (2.3 GB -> 1 GB stripped),
# import libraries are only for compiling, docs and man pages aren't read.
RUN apt-get update && apt-get install -y --no-install-recommends llvm \
 && find /usr/lib/wine -type f \( -name '*.dll' -o -name '*.exe' -o -name '*.sys' -o -name '*.drv' \
      -o -name '*.cpl' -o -name '*.ocx' -o -name '*.dll16' -o -name '*.exe16' -o -name '*.so' \) \
      -exec llvm-strip --strip-debug {} + \
 && find /usr/lib/wine -name '*.a' -delete \
 && apt-get purge -y llvm && apt-get autoremove -y --purge \
 && find /usr/share/doc -type f ! -name copyright -delete \
 && rm -rf /var/lib/apt/lists/* /usr/share/man/* /usr/share/info/* \
      /usr/share/locale/*/LC_MESSAGES/*.mo /var/cache/debconf/*-old /var/log/*.log

COPY --from=unshield /usr/local/bin/unshieldv3 /usr/local/bin/unshieldv3
COPY --from=unshield /licenses/unshieldv3/LICENSE /usr/share/doc/unshieldv3/copyright

# User, autostart session, machine identity.
RUN usermod -l bryce -d /home/bryce -m ubuntu && groupmod -n bryce ubuntu \
 && usermod -aG video,input,render bryce \
 && : > /etc/machine-id \
 && mkdir -p /.overlay

RUN command -v Xorg xrandr setxkbmap openbox wine python3 spice-vdagent spice-vdagentd >/dev/null

COPY guest/ /
RUN chmod 755 /usr/local/bin/bryce-session /usr/local/bin/bryce-firstboot /usr/local/bin/bryce-launch \
      /usr/local/bin/bryce-input /usr/local/bin/bryce-control /usr/local/sbin/bryce-init \
 && systemctl enable bryce-session.service \
 && systemctl mask spice-vdagentd.service spice-vdagentd.socket \
 && systemctl mask getty@tty1.service systemd-networkd-wait-online.service \
      apt-daily.timer apt-daily-upgrade.timer e2scrub_reap.service
