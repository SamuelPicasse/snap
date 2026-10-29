import AppKit
import Carbon
import ServiceManagement

/// Small native settings window (⌘, from the menu bar menu).
@MainActor
final class SettingsWindowController: NSObject {
    private let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let resolution = NSPopUpButton()
    private let lossless = NSButton(checkboxWithTitle: "Lossless (sharper, larger files)", target: nil, action: nil)
    private let folder = NSTextField(labelWithString: "")
    private let login = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private var recorder: ShortcutRecorder? // the one currently recording
    private let hotKeyRegistered: (CaptureMode) -> Bool
    private let setHotKeysEnabled: (Bool) -> Void
    private let checkForUpdates: () -> Void

    init(hotKeyRegistered: @escaping (CaptureMode) -> Bool, setHotKeysEnabled: @escaping (Bool) -> Void, checkForUpdates: @escaping () -> Void) {
        self.hotKeyRegistered = hotKeyRegistered
        self.setHotKeysEnabled = setHotKeysEnabled
        self.checkForUpdates = checkForUpdates
        super.init()
        window.title = "Snap Settings"
        window.isReleasedWhenClosed = false
        // Closing the window mid-recording must not leave the global shortcuts switched off.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRecording() }
        }
    }

    func show() {
        build() // rebuilt on every open, so it reflects the current state (e.g. the shortcut warning)
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func build() {
        resolution.removeAllItems()
        resolution.addItems(withTitles: ["Retina", "1× (smaller files)"])
        resolution.selectItem(at: Settings.retina ? 0 : 1)
        resolution.target = self
        resolution.action = #selector(resolutionChanged)
        lossless.state = Settings.lossless ? .on : .off
        lossless.target = self
        lossless.action = #selector(losslessChanged)
        folder.stringValue = Settings.saveFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        folder.lineBreakMode = .byTruncatingMiddle
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.target = self
        login.action = #selector(loginChanged)

        func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }
        func row(_ views: NSView...) -> NSStackView { NSStackView(views: views) }
        /// Click-to-record button, plus a warning when the shortcut can't be registered.
        func shortcutRow(_ mode: CaptureMode) -> NSStackView {
            let recorder = ShortcutRecorder(title: Settings.shortcut(mode).label, target: self, action: #selector(recordShortcut(_:)))
            recorder.tag = mode.rawValue
            recorder.toolTip = "Click, then press a new shortcut (Esc cancels)"
            let taken = label("Taken by macOS or another app")
            taken.textColor = .systemOrange
            let free = NSButton(title: "Keyboard Settings…", target: self, action: #selector(openKeyboardSettings))
            taken.isHidden = hotKeyRegistered(mode)
            free.isHidden = hotKeyRegistered(mode) || Settings.shortcut(mode) != mode.defaultShortcut // macOS's own
            return row(recorder, taken, free)
        }
        let grid = NSGridView(views: [
            [label("Resolution:"), resolution],
            [NSGridCell.emptyContentView, lossless],
            [label("Save to:"), row(folder, NSButton(title: "Choose…", target: self, action: #selector(chooseFolder)))],
            [NSGridCell.emptyContentView, login],
            [label("Capture area:"), shortcutRow(.area)],
            [label("Capture screen:"), shortcutRow(.screen)],
            [label("Version:"), row(label(Updater.current), NSButton(title: "Check for Updates", target: self, action: #selector(updates)))],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        grid.column(at: 1).width = 300
        for i in [1, 3] { grid.row(at: i).topPadding = -4 } // checkboxes sit under the row above

        grid.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])
        window.contentView = content
    }

    /// Next key press with ⌘ or ⌃ becomes the shortcut; Esc cancels.
    @objc private func recordShortcut(_ sender: ShortcutRecorder) {
        guard recorder == nil, let mode = CaptureMode(rawValue: sender.tag) else { return }
        recorder = sender
        sender.title = "Type shortcut…"
        setHotKeysEnabled(false) // otherwise pressing an existing shortcut would start a capture
        sender.onKey = { [weak self, weak sender] event in
            guard let self, let sender else { return }
            guard event.keyCode != 53 else { return self.stopRecording() } // Esc
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            // macOS only allows global shortcuts that include ⌘ or ⌃ (⌥/⌥⇧-only ones are refused).
            guard !flags.isDisjoint(with: [.command, .control]) else {
                sender.title = "Include ⌘ or ⌃…"
                return NSSound.beep()
            }
            let carbon = [(NSEvent.ModifierFlags.control, controlKey, "⌃"), (.option, optionKey, "⌥"),
                          (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")].filter { flags.contains($0.0) }
            Settings.setShortcut(Settings.Shortcut(keyCode: UInt32(event.keyCode),
                                                   modifiers: UInt32(carbon.reduce(0) { $0 | $1.1 }),
                                                   label: carbon.map(\.2).joined() + Self.keyName(event)), for: mode)
            self.stopRecording()
        }
        window.makeFirstResponder(sender)
    }

    private func stopRecording() {
        guard let recorder else { return }
        recorder.onKey = nil
        self.recorder = nil
        setHotKeysEnabled(true)
        build()
    }

    /// The key itself, without Shift applied ("2", not "@").
    private static func keyName(_ event: NSEvent) -> String {
        let names: [UInt16: String] = [49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑",
                                       122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
                                       98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        return names[event.keyCode] ?? event.characters(byApplyingModifiers: [])?.uppercased() ?? "?"
    }

    @objc private func resolutionChanged() { Settings.retina = resolution.indexOfSelectedItem == 0 }
    @objc private func losslessChanged() { Settings.lossless = lossless.state == .on }
    @objc private func updates() { checkForUpdates() }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Settings.saveFolder
        panel.prompt = "Choose"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            Settings.saveFolder = url
            self.build()
        }
    }

    @objc private func loginChanged() {
        do {
            if login.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSAlert(error: error).beginSheetModal(for: window)
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }

    @objc private func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }
}

/// Button that, while recording, receives every key press — including ⌘ combos, which AppKit
/// routes through performKeyEquivalent and never delivers as a plain keyDown.
final class ShortcutRecorder: NSButton {
    var onKey: ((NSEvent) -> Void)?

    override var acceptsFirstResponder: Bool { onKey != nil }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let onKey, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        onKey(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if let onKey { onKey(event) } else { super.keyDown(with: event) }
    }
}
