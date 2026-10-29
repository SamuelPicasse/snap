import AppKit
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var hotKeys: [CaptureMode: HotKey] = [:]
    private var selection: SelectionController?
    private var editors: [EditorWindowController] = []
    private var replacingEditor = false
    private lazy var settings = SettingsWindowController(hotKeyRegistered: { [weak self] in self?.hotKeys[$0]?.registered == true },
                                                         setHotKeysEnabled: { [weak self] in if $0 { self?.registerHotKeys() } else { self?.hotKeys = [:] } },
                                                         checkForUpdates: { [weak self] in self?.checkForUpdates(userInitiated: true) })
    /// The last screenshot and its marks, kept after the editor closes so an accidental Esc or
    /// close can be undone. Stored as PNG: a cropped CGImage would keep the whole frozen screen alive.
    private var last: (png: Data, scale: CGFloat, annotations: [Annotation])?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Icons.menuBar
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        registerHotKeys()

        // Check for updates now and daily, but never interrupt an open editor.
        Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { self.checkForUpdates(userInitiated: false) }
        }.fire()

        // `open Snap.app --args --open image.png [scale]`: annotate an existing image.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count,
           let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[i + 1]) as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let scale = i + 2 < args.count ? CGFloat(Double(args[i + 2]) ?? 2) : 2
            openEditor(Capture(image: image, scale: scale))
        }
    }

    private func registerHotKeys() {
        hotKeys = [:] // unregister the old ones first
        for mode in CaptureMode.allCases {
            let shortcut = Settings.shortcut(mode)
            hotKeys[mode] = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, id: UInt32(mode.rawValue + 1)) { [weak self] in
                MainActor.assumeIsolated { self?.capture(mode) }
            }
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        for mode in CaptureMode.allCases {
            let item = NSMenuItem(title: "\(mode.title)   \(Settings.shortcut(mode).label)", action: #selector(captureFromMenu(_:)), keyEquivalent: "")
            item.tag = mode.rawValue
            menu.addItem(item)
        }
        let reopen = NSMenuItem(title: "Reopen Last Screenshot", action: last == nil ? nil : #selector(reopenLast), keyEquivalent: "")
        menu.addItem(reopen)
        if hotKeys.values.contains(where: { !$0.registered }) {
            menu.addItem(NSMenuItem(title: "⚠︎ A shortcut is taken — fix it in Settings…", action: #selector(openSettings), keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Quit Snap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
    }

    @objc private func captureFromMenu(_ sender: NSMenuItem) {
        // Let the menu close before freezing the screen.
        let mode = CaptureMode(rawValue: sender.tag) ?? .area
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.capture(mode) }
    }

    @objc private func openSettings() {
        settings.show()
    }

    private func checkForUpdates(userInitiated: Bool) {
        guard userInitiated || (editors.isEmpty && selection == nil) else { return }
        Task { await Updater.check(userInitiated: userInitiated) }
    }

    // MARK: Capture flow

    func capture(_ mode: CaptureMode) {
        guard selection == nil else { return }
        // One editor at a time: a new ⌘⇧3 discards the open one. Close it first so it isn't
        // in the frozen screenshot, and give the window server a moment to remove it.
        if !editors.isEmpty {
            replacingEditor = true
            editors.forEach { $0.close() }
            replacingEditor = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.capture(mode) }
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
                selection = SelectionController(shots: shots, mode: mode) { result in
                    self.selection = nil
                    if let result { self.openEditor(result) } else { NSApp.hide(nil) }
                }
            } catch {
                showAlert("Capture failed", error.localizedDescription)
            }
        }
    }

    private func openEditor(_ capture: Capture, annotations: [Annotation] = []) {
        let editor = EditorWindowController(capture: capture, annotations: annotations)
        editor.onClose = { [weak self, weak editor] in
            if let editor { self?.remember(editor) }
            self?.editors.removeAll { $0 === editor }
            if self?.editors.isEmpty == true, self?.replacingEditor == false { NSApp.hide(nil) }
        }
        editors.append(editor)
        editor.show()
    }

    private func remember(_ editor: EditorWindowController) {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, editor.capture.image, nil)
        guard CGImageDestinationFinalize(dest) else { return }
        last = (data as Data, editor.capture.scale, editor.annotations)
    }

    /// Menu item, or launching Snap again (Spotlight/Finder) while it's running.
    @objc private func reopenLast() {
        if let editor = editors.last { return editor.show() }
        guard let last else { return }
        guard let source = CGImageSourceCreateWithData(last.png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return NSSound.beep() }
        openEditor(Capture(image: image, scale: last.scale), annotations: last.annotations)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        reopenLast()
        return false
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
