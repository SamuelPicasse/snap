import AppKit
import Carbon
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var selection: SelectionController?
    private var editors: [EditorWindowController] = []
    private var replacingEditor = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Snap")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | shiftKey), id: 1) { [weak self] in
            MainActor.assumeIsolated { self?.capture() }
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let capture = NSMenuItem(title: "Capture Area", action: #selector(captureFromMenu), keyEquivalent: "3")
        capture.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(capture)
        if hotKey?.registered != true {
            let warning = NSMenuItem(title: "⚠︎ ⌘⇧3 is taken — disable it in Keyboard Shortcuts", action: #selector(openKeyboardSettings), keyEquivalent: "")
            menu.addItem(warning)
        }
        menu.addItem(.separator())

        let retina = NSMenuItem(title: "Retina Resolution", action: #selector(setRetina), keyEquivalent: "")
        retina.state = Settings.retina ? .on : .off
        menu.addItem(retina)
        let standard = NSMenuItem(title: "1× Resolution (smaller)", action: #selector(setStandard), keyEquivalent: "")
        standard.state = Settings.retina ? .off : .on
        menu.addItem(standard)
        let lossless = NSMenuItem(title: "Lossless (sharper, larger files)", action: #selector(toggleLossless), keyEquivalent: "")
        lossless.state = Settings.lossless ? .on : .off
        menu.addItem(lossless)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Save Folder: \(Settings.saveFolder.lastPathComponent)…", action: #selector(chooseFolder), keyEquivalent: ""))
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Snap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
    }

    @objc private func captureFromMenu() {
        // Let the menu close before freezing the screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.capture() }
    }

    @objc private func setRetina() { Settings.retina = true }
    @objc private func setStandard() { Settings.retina = false }
    @objc private func toggleLossless() { Settings.lossless.toggle() }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Settings.saveFolder
        panel.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { Settings.saveFolder = url }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showAlert("Couldn't change Launch at Login", error.localizedDescription)
        }
    }

    @objc private func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    // MARK: Capture flow

    func capture() {
        guard selection == nil else { return }
        // One editor at a time: a new ⌘⇧3 discards the open one. Close it first so it isn't
        // in the frozen screenshot, and give the window server a moment to remove it.
        if !editors.isEmpty {
            replacingEditor = true
            editors.forEach { $0.close() }
            replacingEditor = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.capture() }
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            let open = showAlert("Snap needs Screen Recording permission",
                                 "Enable Snap in System Settings → Privacy & Security → Screen & System Audio Recording, then try again.",
                                 button: "Open System Settings")
            if open {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            return
        }

        Task {
            do {
                let shots = try await ScreenGrabber.grabAllScreens()
                selection = SelectionController(shots: shots) { result in
                    self.selection = nil
                    if let result { self.openEditor(result) } else { NSApp.hide(nil) }
                }
            } catch {
                showAlert("Capture failed", error.localizedDescription)
            }
        }
    }

    private func openEditor(_ capture: Capture) {
        let editor = EditorWindowController(capture: capture)
        editor.onClose = { [weak self, weak editor] in
            self?.editors.removeAll { $0 === editor }
            if self?.editors.isEmpty == true, self?.replacingEditor == false { NSApp.hide(nil) }
        }
        editors.append(editor)
        editor.show()
    }

    @discardableResult
    private func showAlert(_ title: String, _ message: String, button: String? = nil) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let button {
            alert.addButton(withTitle: button)
            alert.addButton(withTitle: "Cancel")
        }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn && button != nil
    }
}
