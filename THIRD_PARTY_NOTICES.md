# Third-party notices

`make-bryce-app.zsh` (also bundled inside `Bryce 3D Installer.app`) contains
JavaScript ports of the following software. Both ports are altered versions of
the originals and are marked as such in the source.

## unshieldv3

* Source: https://github.com/wfr/unshieldv3 (`ISArchiveV3.cpp`, `ISArchiveV3.h`)
* Copyright (c) 2019 Wolfgang Frisch
* License: Apache License, Version 2.0, full text in
  [`licenses/unshieldv3-Apache-2.0.txt`](licenses/unshieldv3-Apache-2.0.txt)
* Changes: ported from C++ to JavaScript (run by macOS's JavaScript engine through
  `osascript`); the archive is read into memory; path segments `.` and `..` are rejected.

## blast

* Source: `blast.c` / `blast.h` version 1.3, as distributed with zlib (`contrib/blast`)
  and unshieldv3
* Changes: ported from C to JavaScript; output goes to a growing buffer instead of a
  callback.

```
Copyright (C) 2003, 2012, 2013 Mark Adler
version 1.3, 24 Aug 2013

This software is provided 'as-is', without any express or implied
warranty.  In no event will the author be held liable for any damages
arising from the use of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it
freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not
   claim that you wrote the original software. If you use this software
   in a product, an acknowledgment in the product documentation would be
   appreciated but is not required.
2. Altered source versions must be plainly marked as such, and must not be
   misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.

Mark Adler    madler@alumni.caltech.edu
```

## Downloaded at install time (not part of this repository)

* Wine (LGPL-2.1-or-later), macOS builds by Gcenx:
  https://github.com/Gcenx/macOS_Wine_builds
