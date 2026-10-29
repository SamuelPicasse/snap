import AppKit
import ServiceManagement

/// Small native settings window (⌘, from the menu bar menu).
@MainActor
final class SettingsWindowController: NSObject {
    private let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let resolution = NSPopUpButton()
    private let lossless = NSButton(checkboxWithTitle: "Lossless (sharper, larger files)", target: nil, action: nil)
    private let folder = NSTextField(labelWithString: "")
    private let login = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let hotKeyRegistered: () -> Bool
    private let checkForUpdates: () -> Void

    init(hotKeyRegistered: @escaping () -> Bool, checkForUpdates: @escaping () -> Void) {
        self.hotKeyRegistered = hotKeyRegistered
        self.checkForUpdates = checkForUpdates
        super.init()
        window.title = "Snap Settings"
        window.isReleasedWhenClosed = false
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

        let shortcut = NSTextField(labelWithString: hotKeyRegistered() ? "⌘⇧3" : "⌘⇧3 is taken by macOS")
        let free = NSButton(title: "Keyboard Settings…", target: self, action: #selector(openKeyboardSettings))
        free.isHidden = hotKeyRegistered()

        func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }
        func row(_ views: NSView...) -> NSStackView { NSStackView(views: views) }
        let grid = NSGridView(views: [
            [label("Resolution:"), resolution],
            [NSGridCell.emptyContentView, lossless],
            [label("Save to:"), row(folder, NSButton(title: "Choose…", target: self, action: #selector(chooseFolder)))],
            [NSGridCell.emptyContentView, login],
            [label("Shortcut:"), row(shortcut, free)],
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
