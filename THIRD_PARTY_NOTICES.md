# Third-party software

This repository's own code is under the MIT License ([LICENSE](LICENSE)).

**Bryce** (Bryce 2, Bryce 3D, Bryce 4) is © MetaTools / MetaCreations (now Corel).
No part of it is included in this repository or in the app: the app installs Bryce
from the user's own CD.

## In Bryce.app

The app contains a small Linux system (the "runtime"), built from
[`vm/rootfs.Dockerfile`](vm/rootfs.Dockerfile). Its main components:

| Component | License | Source |
|---|---|---|
| Ubuntu 24.04 (Linux kernel, systemd, Xorg, Openbox, spice-vdagent, Python and the other packages it needs) | each package's own license (GPL, LGPL, MIT, BSD and others) | https://launchpad.net/ubuntu |
| [Hangover](https://github.com/AndreRH/hangover) 11.16: Wine for ARM64 with WoW64 | LGPL-2.1-or-later | https://github.com/AndreRH/hangover |
| [FEX](https://github.com/FEX-Emu/FEX) (x86 translator inside Hangover) | MIT | https://github.com/FEX-Emu/FEX |
| [Box64](https://github.com/ptitSeb/box64) (alternative translator shipped with Hangover, not used by default) | MIT | https://github.com/ptitSeb/box64 |
| [unshieldv3](https://github.com/wfr/unshieldv3) by Wolfgang Frisch (unpacks Bryce 2 and 3D CDs) | Apache-2.0 ([text](licenses/unshieldv3-Apache-2.0.txt)) | https://github.com/wfr/unshieldv3 |
| [unshield](https://github.com/twogood/unshield) (Ubuntu package; unpacks Bryce 4 CDs) | MIT | https://github.com/twogood/unshield |

* **License texts:** inside the runtime, every package keeps its license in
  `/usr/share/doc/<package>/copyright`.
* **Complete list** of packages and versions, with links to their source code and the
  written offer for GPL/LGPL source: `SOURCES.md` and `packages.tsv`, attached to every
  release and included in the app (`Bryce.app/Contents/Resources/Licenses`).

## Used while building (not shipped)

Docker and Ubuntu's build tools (runtime image), Xcode Command Line Tools (app),
and LLVM (stripping debug information from Wine's binaries).
