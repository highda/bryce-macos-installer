// Settings and maintenance window (Bryce 3D › Settings…, or hold ⌥ while
// starting the app to open it before Bryce starts).
import AppKit
import SwiftUI

/// Everything the user can set, stored in the local.bryce3d.vm defaults domain.
enum Prefs {
    static let d = UserDefaults(suiteName: "local.bryce3d.vm")!

    /// Window size as a multiple of 640x480 (points); nil = automatic.
    static var scale: Double? {
        get { let v = d.double(forKey: "Scale"); return v > 0 ? v : nil }
        set { if let v = newValue { d.set(v, forKey: "Scale") } else { d.removeObject(forKey: "Scale") } }
    }
    /// Nearest-neighbour scaling inside the VM (default on).
    static var crisp: Bool {
        get { d.object(forKey: "CrispScaling") as? Bool ?? true }
        set { d.set(newValue, forKey: "CrispScaling") }
    }
    /// Fixed XKB layout ("cz", "de:mac", ...); nil = follow macOS.
    static var keyboard: String? {
        get { d.string(forKey: "KeyboardLayout").flatMap { $0.isEmpty ? nil : $0 } }
        set { if let v = newValue, !v.isEmpty { d.set(v, forKey: "KeyboardLayout") } else { d.removeObject(forKey: "KeyboardLayout") } }
    }
    /// The Command key acts as Ctrl in Bryce (Cmd-C/V/S).
    static var commandAsControl: Bool {
        get { d.bool(forKey: "CommandAsControl") }
        set { d.set(newValue, forKey: "CommandAsControl") }
    }
    /// Maintenance the VM does on its next boot ("registration", "prefs").
    static var pendingResets: [String] {
        get { d.stringArray(forKey: "PendingResets") ?? [] }
        set { d.set(Array(Set(newValue)).sorted(), forKey: "PendingResets") }
    }
}

/// What the settings window can ask the app to do.
struct SettingsActions {
    var start: () -> Void           // start Bryce (window opened before start)
    var restart: () -> Void         // restart Bryce so changes take effect
    var reinstall: () -> Void       // delete the data disk, ask for the CD next time
    var removeAll: () -> Void       // delete all Bryce 3D app data, then quit
}

struct SettingsView: View {
    let running: Bool
    let actions: SettingsActions
    let projects: URL

    @State private var scale = Prefs.scale ?? 0
    @State private var crisp = Prefs.crisp
    @State private var keyboard = Prefs.keyboard ?? ""
    @State private var cmdCtrl = Prefs.commandAsControl
    @State private var pending = Prefs.pendingResets

    private var autoScale: CGFloat { Display.automaticScale(screen: NSScreen.main) }
    private var choices: [CGFloat] { Display.scaleChoices(screen: NSScreen.main) }
    private func label(_ s: CGFloat) -> String {
        let n = s == s.rounded() ? String(format: "%.0f", s) : String(format: "%.1f", s)
        return "\(n)×  (\(Int(640 * s)) × \(Int(480 * s)))"
    }

    var body: some View {
      VStack(spacing: 0) {
        Form {
            Section("Display") {
                Picker("Window size", selection: $scale) {
                    Text("Automatic – \(label(autoScale))").tag(0.0)
                    ForEach(choices, id: \.self) { s in Text(label(s)).tag(Double(s)) }
                }
                .onChange(of: scale) { _, v in Prefs.scale = v > 0 ? v : nil }
                Toggle("Crisp pixels", isOn: $crisp)
                    .onChange(of: crisp) { _, v in Prefs.crisp = v }
                Text("Bryce draws 640 × 480. Crisp pixels enlarges it without blurring.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Keyboard") {
                Picker("Layout", selection: $keyboard) {
                    Text("Same as macOS").tag("")
                    ForEach(Keyboard.choices, id: \.value) { c in Text(c.name).tag(c.value) }
                }
                .onChange(of: keyboard) { _, v in Prefs.keyboard = v.isEmpty ? nil : v }
                Toggle("⌘ Command acts as Ctrl", isOn: $cmdCtrl)
                    .onChange(of: cmdCtrl) { _, v in Prefs.commandAsControl = v }
                Text("Bryce is a Windows program: its shortcuts and copy/paste use Ctrl. With this on, ⌘C, ⌘V, ⌘S… work too.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Scenes and renders") {
                LabeledContent("Folder") {
                    Text("Documents › Bryce 3D  (E:\\ in Bryce)")
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([projects]) }
            }
            Section("Maintenance") {
                maintenance("Reset registration",
                            "Bryce asks for your name and serial number again.",
                            reset: "registration")
                maintenance("Reset Bryce's own settings",
                            "Deletes Bryce's preferences file, in case Bryce behaves oddly. Your scenes and presets stay.",
                            reset: "prefs")
                HStack {
                    VStack(alignment: .leading) {
                        Text("Reinstall from CD")
                        Text("Removes the installed Bryce, its settings and registration. You choose the CD again. Your scenes stay.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reinstall…") { actions.reinstall() }
                }
                HStack {
                    VStack(alignment: .leading) {
                        Text("Remove all Bryce 3D data")
                        Text("Before deleting the app. Your scenes in Documents › Bryce 3D stay.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove…") { actions.removeAll() }
                }
            }
        }
        .formStyle(.grouped)
        // Action bar below the form (not floating over it).
        Divider()
        HStack {
            Text(running ? "Changes apply the next time Bryce starts." : "")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if running {
                Button("Restart Bryce 3D") { actions.restart() }
            } else {
                Button("Start Bryce 3D") { actions.start() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
      }
      .frame(width: 520, height: 680)
    }

    @ViewBuilder
    private func maintenance(_ title: String, _ detail: String, reset: String) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if pending.contains(reset) {
                Button("Cancel") { pending.removeAll { $0 == reset }; Prefs.pendingResets = pending }
            } else {
                Button("On next start") { pending.append(reset); Prefs.pendingResets = pending }
            }
        }
    }
}

/// Shows a yes/no question; true if the user confirmed.
func confirm(_ title: String, _ text: String, button: String, destructive: Bool = true) -> Bool {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = text
    a.alertStyle = destructive ? .warning : .informational
    let b = a.addButton(withTitle: button)
    b.hasDestructiveAction = destructive
    a.addButton(withTitle: "Cancel")
    return a.runModal() == .alertFirstButtonReturn
}
