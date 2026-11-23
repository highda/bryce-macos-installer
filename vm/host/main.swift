// Bryce 3D host: runs the Linux runtime VM (Hangover Wine + FEX + Bryce)
// with Apple's Virtualization.framework and shows its display in a window.
//
// In the app bundle the runtime (Image = kernel, root.img = read-only system)
// is in Contents/Resources/runtime. Bryce itself is never included: on the
// first start the app asks for the user's CD image and the VM unpacks it onto
// the data disk (~/Library/Application Support/Bryce 3D/data.img).
// Scenes and renders: ~/Documents/Bryce 3D (E:\ inside Bryce).
//
// Development: BryceVM [--runtime DIR] [--data FILE] [--iso FILE] [--projects DIR]
// BRYCE_DEBUG=1 shows kernel messages in vm-console.log and enables the
// vm-control.fifo command channel ("sh CMD" runs CMD as root in the VM).
import AppKit
import Carbon
import SwiftUI
import Virtualization

struct Options {
    var runtime: URL
    var data: URL
    var iso: URL?
    var projects: URL
    var console: URL
    var support: URL
    let debug = ProcessInfo.processInfo.environment["BRYCE_DEBUG"] != nil

    /// Open Settings instead of starting Bryce (like holding ⌥ at launch).
    var settingsOnly = false

    /// Written when the VM reports that Bryce is on the data disk (kept next to it).
    var installedMarker: URL { data.deletingLastPathComponent().appendingPathComponent("installed") }

    init() {
        let fm = FileManager.default
        support = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Bryce 3D", isDirectory: true)
        runtime = Bundle.main.resourceURL!.appendingPathComponent("runtime", isDirectory: true)
        data = support.appendingPathComponent("data.img")
        console = support.appendingPathComponent("vm-console.log")
        projects = fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Bryce 3D", isDirectory: true)
        var it = CommandLine.arguments.dropFirst().makeIterator()
        while let a = it.next() {
            if a == "--settings" { settingsOnly = true; continue }
            guard let v = it.next() else { break }
            switch a {
            case "--runtime": runtime = URL(fileURLWithPath: v, isDirectory: true)
            case "--data": data = URL(fileURLWithPath: v)
            case "--iso": iso = URL(fileURLWithPath: v)
            case "--projects": projects = URL(fileURLWithPath: v, isDirectory: true)
            default: break
            }
        }
    }
}

/// Crisp scaling. Bryce draws 640x480; the VM's display is `pixelScale` times
/// that in physical pixels, enlarged inside the VM with nearest-neighbour, and
/// the window shows those pixels 1:1. On Retina, 1.5x in points is 3x in pixels,
/// so every 0.5 step is a whole number of pixels.
struct Display {
    static let base = (w: 640, h: 480)        // Bryce 3D's native layout
    let pointScale: CGFloat                   // window size / 640x480, in points
    let pixelScale: Int                       // VM display / 640x480, in pixels

    /// Largest whole-pixel scale that fits the screen (title bar included).
    static func automaticScale(screen: NSScreen?) -> CGFloat {
        let step = 1 / (screen?.backingScaleFactor ?? 2)
        let f = screen?.visibleFrame.size ?? NSSize(width: 1280, height: 960)
        let fit = min(f.width / CGFloat(base.w), (f.height - 32) / CGFloat(base.h))
        return max(step, (fit / step).rounded(.down) * step)
    }

    /// Whole-pixel scales (0.5 steps on Retina) from 1x up to what fits the screen.
    /// Whole-pixel scales (0.5 steps on Retina) from 1x up to what fits the
    /// screen, and always up to at least 2x (larger sizes use full screen).
    static func scaleChoices(screen: NSScreen?) -> [CGFloat] {
        let step = 1 / (screen?.backingScaleFactor ?? 2)
        let top = max(automaticScale(screen: screen), 2)
        return stride(from: max(1, step), through: top, by: step).map { $0 }
    }

    /// True if a window of this scale (title bar included) fits on the screen.
    static func fitsInWindow(_ scale: CGFloat, screen: NSScreen?) -> Bool {
        let f = screen?.visibleFrame.size ?? NSSize(width: 1280, height: 960)
        return CGFloat(base.w) * scale <= f.width && CGFloat(base.h) * scale + 32 <= f.height
    }

    init(screen: NSScreen?) {
        let backing = screen?.backingScaleFactor ?? 2
        let step = 1 / backing
        if let v = Prefs.scale {
            pointScale = max(step, (CGFloat(v) / step).rounded() * step)
        } else {
            pointScale = Display.automaticScale(screen: screen)
        }
        // Crisp (nearest-neighbour) scaling inside the VM unless turned off in Settings.
        pixelScale = Prefs.crisp ? max(1, Int((pointScale * backing).rounded())) : 1
    }

    var pixels: (w: Int, h: Int) { (Display.base.w * pixelScale, Display.base.h * pixelScale) }
    var points: NSSize { NSSize(width: CGFloat(Display.base.w) * pointScale, height: CGFloat(Display.base.h) * pointScale) }
}

/// Maps the current macOS keyboard layout to an XKB layout[:variant] for the VM.
enum Keyboard {
    static let table: [String: String] = [
        "US": "us", "ABC": "us", "USExtended": "us", "USInternational-PC": "us:intl",
        "Dvorak": "us:dvorak", "Colemak": "us:colemak",
        "Czech": "cz", "Czech-QWERTY": "cz:qwerty", "Slovak": "sk", "Slovak-QWERTY": "sk:qwerty",
        "German": "de:mac", "Austrian": "at:mac", "SwissGerman": "ch:de_mac", "SwissFrench": "ch:fr_mac",
        "British": "gb:mac", "British-PC": "gb", "Irish": "ie", "French": "fr:mac", "French-PC": "fr",
        "Belgian": "be", "Italian": "it:mac", "Italian-Pro": "it:mac", "Spanish": "es:mac", "Spanish-ISO": "es",
        "Portuguese": "pt:mac", "Brazilian": "br", "Dutch": "nl:mac", "Danish": "dk:mac",
        "Swedish": "se:mac", "Swedish-Pro": "se:mac", "Norwegian": "no:mac", "Finnish": "fi:mac",
        "Icelandic": "is", "Polish": "pl", "PolishPro": "pl", "Hungarian": "hu", "Croatian": "hr",
        "Slovenian": "si", "Romanian": "ro", "Serbian-Latin": "rs:latin", "Bulgarian": "bg",
        "Lithuanian": "lt", "Latvian": "lv", "Estonian": "ee", "Russian": "ru:mac", "Ukrainian": "ua",
        "Turkish": "tr", "Greek": "gr", "Hebrew": "il",
    ]

    /// Layouts offered in Settings, one entry per XKB layout.
    static var choices: [(name: String, value: String)] {
        var seen = Set<String>()
        return table.sorted { $0.key < $1.key }.compactMap { k, v in
            seen.insert(v).inserted ? (name: "\(k) (\(v))", value: v) : nil
        }
    }

    /// The layout to use: fixed in Settings, else the one selected in macOS.
    static func effective() -> String { Prefs.keyboard ?? current() }

    /// "cz", "de:mac", ... for the layout selected in macOS right now.
    static func current() -> String {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return "us" }
        let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        let name = id.replacingOccurrences(of: "com.apple.keylayout.", with: "")
        if let x = table[name] { return x }
        // Unknown layout: fall back to its language code, which XKB usually knows.
        if let langs = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages) {
            let list = Unmanaged<CFArray>.fromOpaque(langs).takeUnretainedValue() as? [String]
            if let lang = list?.first?.prefix(2) { return String(lang) }
        }
        return "us"
    }
}

func fail(_ msg: String) -> Never {
    let alert = NSAlert()
    alert.messageText = "Bryce 3D can't start"
    alert.informativeText = msg
    alert.alertStyle = .critical
    alert.runModal()
    exit(1)
}

/// Creates a sparse disk file of the given size if it doesn't exist yet.
func ensureSparseDisk(_ url: URL, gigabytes: UInt64) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: url.path) { return }
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    fm.createFile(atPath: url.path, contents: nil)
    let h = try FileHandle(forWritingTo: url)
    try h.truncate(atOffset: gigabytes << 30)
    try h.close()
}

/// First start: explain, let the user pick their Bryce 3D CD, and turn it into
/// something the VM can read as an ISO9660 disk. Returns nil if they cancel.
func chooseCDImage(cache: URL) -> URL? {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.messageText = "Install Bryce 3D"
    a.informativeText = """
        Bryce 3D is set up once from your own Bryce 3D CD (Windows edition, 1997). \
        Choose a disc image of it (.iso, .cdr, .toast or .dmg), the inserted CD, or a folder with a copy of it.

        Afterwards Bryce asks for your name and serial number once.
        """
    a.addButton(withTitle: "Choose CD…")
    a.addButton(withTitle: "Quit")
    guard a.runModal() == .alertFirstButtonReturn else { return nil }

    let panel = NSOpenPanel()
    panel.message = "Choose your Bryce 3D CD image, the CD itself, or a folder with a copy of it"
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.treatsFilePackagesAsDirectories = false
    guard panel.runModal() == .OK, let src = panel.url else { return nil }

    let fm = FileManager.default
    try? fm.removeItem(at: cache)
    try? fm.createDirectory(at: cache, withIntermediateDirectories: true)
    func hdiutil(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
    var isDir: ObjCBool = false
    fm.fileExists(atPath: src.path, isDirectory: &isDir)
    if isDir.boolValue {
        // A folder or the mounted CD: build an ISO of it.
        let out = cache.appendingPathComponent("cd.iso")
        if hdiutil(["makehybrid", "-iso", "-joliet", "-o", out.path, src.path]) { return out }
    } else if ["iso", "cdr", "toast"].contains(src.pathExtension.lowercased()) {
        return src
    } else {
        // Other disk images (e.g. compressed .dmg): convert to a raw CD image.
        let out = cache.appendingPathComponent("cd.cdr")
        if hdiutil(["convert", src.path, "-format", "UDTO", "-o", out.path]) { return out }
    }
    fail("macOS can't read “\(src.lastPathComponent)” as a CD image.")
}

func makeConfiguration(_ o: Options, display: Display, control: Pipe, fromGuest: Pipe) throws -> VZVirtualMachineConfiguration {
    let fm = FileManager.default
    try ensureSparseDisk(o.data, gigabytes: 8)
    try fm.createDirectory(at: o.projects, withIntermediateDirectories: true)

    let boot = VZLinuxBootLoader(kernelURL: o.runtime.appendingPathComponent("Image"))
    boot.commandLine = "console=hvc0 root=/dev/vda ro rootwait init=/usr/local/sbin/bryce-init panic=10 bryce.uid=\(getuid())"
        + " bryce.scale=\(display.pixelScale) bryce.kbd=\(Keyboard.effective())"
        + " bryce.time=\(Int(Date().timeIntervalSince1970))"        // the VM has no clock of its own
        + (Prefs.commandAsControl ? " bryce.cmdctrl=1" : "")
        + (Prefs.pendingResets.isEmpty ? "" : " bryce.reset=" + Prefs.pendingResets.joined(separator: ","))
        + (o.debug ? " bryce.debug=1" : " quiet")

    let cfg = VZVirtualMachineConfiguration()
    cfg.bootLoader = boot
    cfg.cpuCount = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount))
    cfg.memorySize = 3 << 30
    cfg.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    cfg.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

    var disks: [VZStorageDeviceConfiguration] = [
        VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(
            url: o.runtime.appendingPathComponent("root.img"), readOnly: true)),
        VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(
            url: o.data, readOnly: false)),
    ]
    if let iso = o.iso {
        disks.append(VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(
            url: iso, readOnly: true)))
    }
    cfg.storageDevices = disks

    let share = VZVirtioFileSystemDeviceConfiguration(tag: "projects")
    share.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: o.projects, readOnly: false))
    cfg.directorySharingDevices = [share]

    fm.createFile(atPath: o.console.path, contents: nil)
    let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
    serial.attachment = VZFileHandleSerialPortAttachment(
        fileHandleForReading: nil, fileHandleForWriting: try FileHandle(forWritingTo: o.console))
    // Second console port (/dev/hvc1 in the VM): commands to the VM ("kbd cz")
    // and messages back from it ("exit" when Bryce has quit).
    let ctl = VZVirtioConsoleDeviceSerialPortConfiguration()
    ctl.attachment = VZFileHandleSerialPortAttachment(
        fileHandleForReading: control.fileHandleForReading,
        fileHandleForWriting: fromGuest.fileHandleForWriting)
    cfg.serialPorts = [serial, ctl]

    // Clipboard shared with the VM (Spice agent; spice-vdagent runs in the VM).
    let spice = VZVirtioConsoleDeviceConfiguration()
    let spicePort = VZVirtioConsolePortConfiguration()
    spicePort.name = VZSpiceAgentPortAttachment.spiceAgentPortName
    let spiceAgent = VZSpiceAgentPortAttachment()
    spiceAgent.sharesClipboard = true
    spicePort.attachment = spiceAgent
    spice.ports[0] = spicePort
    cfg.consoleDevices = [spice]

    let gpu = VZVirtioGraphicsDeviceConfiguration()
    gpu.scanouts = [VZVirtioGraphicsScanoutConfiguration(
        widthInPixels: display.pixels.w, heightInPixels: display.pixels.h)]
    cfg.graphicsDevices = [gpu]
    cfg.keyboards = [VZUSBKeyboardConfiguration()]
    cfg.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

    try cfg.validate()
    return cfg
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, VZVirtualMachineDelegate {
    var window: NSWindow?
    var settingsWindow: NSWindow?
    var vm: VZVirtualMachine?
    let control = Pipe()
    let fromGuest = Pipe()

    var dataLock: Int32 = -1
    var options = Options()
    var vmView: VZVirtualMachineView?
    var relativeDrag = false
    var pressLocation: NSPoint?
    var guestError: String?
    var quitting = false

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()

        // One VM per data disk: a second copy would corrupt it.
        try? FileManager.default.createDirectory(at: options.support, withIntermediateDirectories: true)
        dataLock = open(options.data.path + ".lock", O_CREAT | O_RDWR, 0o600)
        if dataLock < 0 || flock(dataLock, LOCK_EX | LOCK_NB) != 0 {
            let me = ProcessInfo.processInfo.processIdentifier
            if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                .first(where: { $0.processIdentifier != me }) {
                other.activate()
                exit(0)
            }
            fail("Bryce 3D is already running.")
        }

        // Hold ⌥ while starting: settings and maintenance before Bryce starts.
        if NSEvent.modifierFlags.contains(.option) || options.settingsOnly {
            showSettings()
        } else {
            startBryce()
        }
    }

    // MARK: Menu

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Bryce 3D", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Bryce 3D", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Bryce 3D", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let fs = viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.control, .command]
        viewItem.submenu = viewMenu
        let winItem = NSMenuItem()
        main.addItem(winItem)
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = winMenu
        NSApp.mainMenu = main
        NSApp.windowsMenu = winMenu
    }

    @objc func openSettings() { showSettings() }

    func showSettings() {
        if let w = settingsWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let actions = SettingsActions(
            start: { [weak self] in self?.settingsWindow?.close(); self?.startBryce() },
            restart: { [weak self] in self?.restart() },
            reinstall: { [weak self] in self?.reinstall() },
            removeAll: { [weak self] in self?.removeAll() })
        let view = SettingsView(running: vm != nil, actions: actions, projects: options.projects)
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Bryce 3D Settings"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        settingsWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Starting Bryce

    func startBryce() {
        var o = options
        // First start: Bryce isn't on the data disk yet, so it needs the CD.
        let cache = o.support.appendingPathComponent("cd-cache", isDirectory: true)
        try? FileManager.default.removeItem(at: cache)
        if o.iso == nil && !FileManager.default.fileExists(atPath: o.installedMarker.path) {
            guard let iso = chooseCDImage(cache: cache) else { exit(0) }
            o.iso = iso
        }
        options = o

        let display = Display(screen: NSScreen.main)
        let cfg: VZVirtualMachineConfiguration
        do { cfg = try makeConfiguration(o, display: display, control: control, fromGuest: fromGuest) } catch { fail("\(error.localizedDescription)") }
        Prefs.pendingResets = []          // handed to the VM on this boot
        let vm = VZVirtualMachine(configuration: cfg)
        vm.delegate = self
        self.vm = vm

        // Messages from the VM, one per line:
        //   installed      Bryce is on the data disk (sent on every boot)
        //   error TEXT     setup failed (shown to the user)
        //   exit           Bryce has quit and the data is flushed: close the app
        //                  (even if the guest's power-off stalls)
        var pending = ""
        fromGuest.fileHandleForReading.readabilityHandler = { [weak self] h in
            pending += String(decoding: h.availableData, as: UTF8.self)
            // The guest's tty sends "\r\n", which Swift treats as one Character,
            // so look for any newline character rather than "\n".
            while let nl = pending.firstIndex(where: { $0.isNewline }) {
                let line = pending[..<nl].trimmingCharacters(in: .whitespacesAndNewlines)
                pending.removeSubrange(...nl)
                DispatchQueue.main.async { self?.guestMessage(line) }
            }
        }

        // Development: lines written to vm-control.fifo in Application Support
        // are forwarded to the VM's control port (e.g. "sh xrandr --verbose").
        let fifo = o.support.appendingPathComponent("vm-control.fifo").path
        unlink(fifo)
        if o.debug, mkfifo(fifo, 0o600) == 0 {
            let out = control.fileHandleForWriting
            Thread.detachNewThread {
                while let h = FileHandle(forReadingAtPath: fifo) {
                    let data = h.readDataToEndOfFile()
                    if !data.isEmpty { out.write(data) }
                    try? h.close()
                }
            }
        }

        // Follow macOS keyboard layout changes (e.g. ⌃Space), unless fixed in Settings.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { [weak self] _ in
                guard Prefs.keyboard == nil else { return }
                let k = Keyboard.current().split(separator: ":").joined(separator: " ")
                self?.control.fileHandleForWriting.write(Data("kbd \(k)\n".utf8))
            }

        let view = VZVirtualMachineView()
        view.virtualMachine = vm
        view.capturesSystemKeys = true
        // Fixed size: the VM's pixels map 1:1 to the screen's, so nothing gets
        // blurred. In full screen it is centred on black (and cropped if larger).
        let size = display.points
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        view.frame = container.bounds
        view.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        container.addSubview(view)
        vmView = view

        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Bryce 3D"
        w.contentView = container
        w.contentMinSize = size
        w.contentMaxSize = size
        w.collectionBehavior = [.fullScreenPrimary]
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(view)
        window = w
        NSApp.activate(ignoringOtherApps: true)
        if !Display.fitsInWindow(display.pointScale, screen: NSScreen.main) {
            w.toggleFullScreen(nil)
        }

        // Endless drags: while the VM reports a relative drag ("rel 1"), hide
        // the cursor and move it back to the middle whenever it nears an edge.
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown,
                                                     .leftMouseDragged, .rightMouseDragged,
                                                     .otherMouseDragged, .mouseMoved,
                                                     .leftMouseUp, .rightMouseUp, .otherMouseUp]) { [weak self] e in
            self?.trackPointer(e)
            return e
        }

        vm.start { result in
            if case .failure(let e) = result { fail("The virtual machine did not start: \(e.localizedDescription)") }
        }
    }

    func guestMessage(_ line: String) {
        // Keep a record of what the VM reported (vm-host.log, next to the data disk).
        let logURL = options.support.appendingPathComponent("vm-host.log")
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(Data("\(Date()) \(line)\n".utf8)); try? h.close()
        } else {
            try? Data("\(Date()) \(line)\n".utf8).write(to: logURL)
        }
        if line == "rel 1" || line == "rel 0" {
            setRelativeDrag(line == "rel 1")
            return
        }
        if line == "installed" {
            FileManager.default.createFile(atPath: options.installedMarker.path, contents: nil)
            try? FileManager.default.removeItem(at: options.support.appendingPathComponent("cd-cache"))
        } else if line.hasPrefix("error ") {
            guestError = String(line.dropFirst(6))
        } else if line == "exit" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.finish() }
        }
    }

    // MARK: Endless drags

    func setRelativeDrag(_ on: Bool) {
        guard on != relativeDrag else { return }
        relativeDrag = on
        if on {
            NSCursor.hide()
        } else {
            // Put the cursor back where the drag started, then show it.
            if let o = pressLocation { warpCursor(to: o) }
            NSCursor.unhide()
        }
    }

    /// Moves the Mac cursor to a point in screen coordinates (origin bottom-left).
    func warpCursor(to p: NSPoint) {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: p.x, y: top - p.y))
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    func trackPointer(_ e: NSEvent) {
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(e.type) {
            pressLocation = NSEvent.mouseLocation    // where a drag would start
            return
        }
        guard relativeDrag, let view = vmView, let w = window, e.window == w else { return }
        if [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(e.type) {
            setRelativeDrag(false)              // in case "rel 0" is late
            return
        }
        let area = view.visibleRect               // the part on screen (full screen may crop)
        let p = view.convert(e.locationInWindow, from: nil)
        let margin = min(area.width, area.height) * 0.2
        guard p.x < area.minX + margin || p.x > area.maxX - margin ||
              p.y < area.minY + margin || p.y > area.maxY - margin else { return }
        // Re-centre. The VM sees one large jump and ignores it (bryce-input).
        let mid = view.convert(NSPoint(x: area.midX, y: area.midY), to: nil)
        warpCursor(to: w.convertPoint(toScreen: mid))
    }

    // Full screen: let the window grow to the screen, restore the fixed size after.
    func windowWillEnterFullScreen(_ note: Notification) {
        window?.contentMaxSize = NSSize(width: 100_000, height: 100_000)
    }

    func windowDidExitFullScreen(_ note: Notification) {
        guard let w = window, let v = vmView else { return }
        w.contentMaxSize = v.frame.size
        w.setContentSize(v.frame.size)
    }

    // MARK: Stopping

    /// Stops the VM (if running), then runs `then` on the main queue.
    func stopVM(then: @escaping () -> Void) {
        quitting = true
        guard let vm = vm, vm.canStop else { then(); return }
        vm.stop { _ in DispatchQueue.main.async(execute: then) }
    }

    /// Bryce has quit (or setup failed): show a setup error if there was one, then quit.
    func finish() {
        if let msg = guestError {
            guestError = nil
            window?.orderOut(nil)
            let a = NSAlert()
            a.messageText = "Bryce 3D could not be set up"
            a.informativeText = msg + "\n\nStart Bryce 3D again to choose the CD image again."
            a.alertStyle = .warning
            a.runModal()
        }
        stopVM { exit(0) }
    }

    /// Quit and start the app again (new settings apply at boot).
    func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        exit(0)
    }

    func restart() {
        guard vm != nil else { settingsWindow?.close(); startBryce(); return }
        guard confirm("Restart Bryce 3D?",
                      "Bryce will be closed and started again with the new settings. Save your scene in Bryce first: unsaved changes are lost.",
                      button: "Restart", destructive: false) else { return }
        stopVM { self.relaunch() }
    }

    func reinstall() {
        guard confirm("Reinstall Bryce 3D from the CD?",
                      "This removes the installed Bryce 3D, its settings and your registration. Next, you choose the CD again and enter your serial number. Your scenes in Documents › Bryce 3D are kept.",
                      button: "Reinstall") else { return }
        stopVM {
            self.deleteData(keepingSettings: true)
            self.relaunch()
        }
    }

    func removeAll() {
        guard confirm("Remove all Bryce 3D data?",
                      "This removes the installed Bryce 3D, its settings, your registration and this app's preferences. Your scenes in Documents › Bryce 3D are kept. Afterwards you can delete the app itself.",
                      button: "Remove") else { return }
        stopVM {
            self.deleteData(keepingSettings: false)
            let a = NSAlert()
            a.messageText = "Bryce 3D data removed"
            a.informativeText = "You can now move Bryce 3D to the Trash."
            a.runModal()
            exit(0)
        }
    }

    /// Deletes this app's files in Application Support (not other files there).
    func deleteData(keepingSettings: Bool) {
        let fm = FileManager.default
        for name in ["data.img", "installed", "cd-cache", "vm-console.log", "vm-host.log", "vm-control.fifo"] {
            try? fm.removeItem(at: options.support.appendingPathComponent(name))
        }
        if !keepingSettings {
            UserDefaults.standard.removePersistentDomain(forName: "local.bryce3d.vm")
            try? fm.removeItem(at: options.data.appendingPathExtension("lock"))
            if (try? fm.contentsOfDirectory(atPath: options.support.path))?.isEmpty == true {
                try? fm.removeItem(at: options.support)
            }
        }
    }

    // MARK: Window and app lifecycle

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender == window, !quitting else { return true }
        return confirm("Quit Bryce 3D?", "Unsaved changes in Bryce are lost. To keep them, save your scene in Bryce first.",
                       button: "Quit", destructive: true)
    }

    func windowWillClose(_ note: Notification) {
        guard let w = note.object as? NSWindow else { return }
        if w == settingsWindow {
            settingsWindow = nil
            if vm == nil && !quitting { exit(0) }      // closed before starting Bryce
        } else if w == window {
            stopVM { exit(0) }
        }
    }

    func applicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        guard vm != nil, !quitting else { return .terminateNow }
        guard confirm("Quit Bryce 3D?", "Unsaved changes in Bryce are lost. To keep them, save your scene in Bryce first.",
                      button: "Quit", destructive: true) else { return .terminateCancel }
        stopVM { exit(0) }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }
    func guestDidStop(_ vm: VZVirtualMachine) { if guestError != nil { finish() } else { exit(0) } }
    func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) {
        fail("The virtual machine stopped: \(error.localizedDescription)")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
