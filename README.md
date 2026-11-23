# Bryce 3D for Apple Silicon Macs

Turns **your own** Bryce 3D CD (MetaCreations, 1997, Windows edition) into a normal Mac app, `Bryce 3D.app`, that runs on Apple Silicon through Wine and Rosetta 2.

* No Docker, Homebrew, Xcode or separate Wine install, before or after.
* Much faster than running Bryce in an emulated container (Rosetta translates the code instead of emulating a whole PC). Bryce renders on the CPU, so this is where the speed matters.
* Bryce's 640×480 interface is scaled up to fit your screen (200% on a typical MacBook).

Nothing from Bryce is included or downloaded. You bring your CD and your serial number. The app you build contains your licensed copy and your registration: **don't share the built app**, share this installer instead.

## Install

1. Download **Bryce-3D-Installer.dmg** from the [latest release](../../releases/latest) and open it.
2. Open **Bryce 3D Installer** from the disk that appears. There's no need to copy it anywhere.
   The first time, macOS may say it can't verify the app. Click **Done**, then open **System Settings › Privacy & Security**, scroll down and click **Open Anyway** next to "Bryce 3D Installer". (This happens because the installer isn't notarized by Apple.)
3. Drag your Bryce 3D CD image onto the installer, or click **Choose CD Image…**. Any of these work:
   * an `.iso` image of the CD
   * a `.cdr`, `.dmg` or `.toast` image
   * the CD itself (choose it with **Choose CD or Folder…**), or a folder with a copy of it
4. Have your serial number ready and click **Install**. You can paste the serial into the installer and it will be on the clipboard for later.
5. After a few minutes, Bryce opens its registration window once. Enter your name, organisation and serial, then click **OK**. (Can't see it? Click the Wine icon in the Dock.)
6. Done. Bryce 3D is in your Applications folder.

The installer needs an internet connection (it downloads the Wine engine, about 200 MB) and about 3 GB of free space while it works. The finished app takes 1.5 GB. If Rosetta 2 isn't installed yet, the installer offers to install it.

## Using Bryce 3D.app

* **Scenes and renders:** `Documents › Bryce 3D`. Inside Bryce this is `C:\Bryce3D\Projects` and drive `E:`.
* **The CD's libraries, sample scenes and tutorials:** drive `D:` inside Bryce.
* **Interface size:** chosen automatically. To set it yourself, run in Terminal
  `defaults write local.bryce3d.wine Scale 1.5` (any value; `1` turns scaling off, `defaults delete local.bryce3d.wine Scale` goes back to automatic).
* **Bryce's own settings** live in `~/Library/Application Support/Bryce 3D`. Reinstalling keeps the previous copy there as `prefix.old-<date>`.
* The app works from any folder; you can move it.

To uninstall, delete `Bryce 3D.app` and `~/Library/Application Support/Bryce 3D`.

## Command line

The installer is a front end for one script that you can also run directly:

```
zsh make-bryce-app.zsh /path/to/Bryce3DCD.iso
```

`zsh make-bryce-app.zsh --help` lists the options (`--out`, `--serial`, `--wine-tarball`, `--wine-flavor`, `--icon`, `--keep-work`).

## Building the installer

```
zsh build-installer.zsh                # → dist/Bryce 3D Installer.app and .dmg
zsh build-installer.zsh --sign "Developer ID Application: …"
```

Only tools that ship with macOS are used. Without a Developer ID, the app is signed ad hoc and users see the "Open Anyway" step above. With one, also notarize the disk image (`xcrun notarytool submit … --wait`, then `xcrun stapler staple` on the .dmg) and that step goes away.

GitHub Actions (`.github/workflows/build.yml`) checks the scripts and builds the disk image on every push. Pushing a tag such as `v1.0.0` publishes a release with `Bryce-3D-Installer.dmg` attached.

## How it works

1. `data.1` (an InstallShield 3 archive) is read straight from the CD image and unpacked by a JavaScript port of [unshieldv3](https://github.com/wfr/unshieldv3) that runs in macOS's built-in JavaScript engine. The 16-bit `SETUP.EXE` never runs. (Idea from [BryceDock](https://github.com/RaymonDev/BryceDock).)
2. A Wine build from [Gcenx/macOS_Wine_builds](https://github.com/Gcenx/macOS_Wine_builds) is downloaded and bundled into the app.
3. A Wine prefix is prepared: Bryce in `C:\Bryce3D`, CD content on `D:`, Windows XP mode (Windows 98 mode makes Bryce hang under Rosetta).
4. Bryce is registered once, so the registration is part of the app.
5. The app's launcher copies the prefix to Application Support on first launch, links your Documents folder and sets the interface scale.

## Known limits

* Needs Rosetta 2, which Apple plans to scale back after macOS 27.
* Tested on macOS 27.0.1 (Apple Silicon) with Wine 11.21.
* Not tested yet: QuickTime/AVI animation export.

## Credits

* unshieldv3 by Wolfgang Frisch (Apache License 2.0); blast.c by Mark Adler (zlib license). Both ported to JavaScript in `make-bryce-app.zsh`; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
* Wine (LGPL) via Gcenx's macOS builds.
* BryceDock by RaymonDev for the extraction approach.
