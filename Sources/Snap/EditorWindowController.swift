import AppKit

/// Editor window: drawing tools in the titlebar toolbar, beautify settings in a sidebar that
/// slides in when ✨ is on, and the canvas filling the rest.
@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    var onClose: (() -> Void)?
    private(set) var capture: Capture
    var annotations: [Annotation] { canvas.annotations }
    private let window: EditorWindow
    private let canvas: CanvasView
    private let sidebar = NSVisualEffectView()
    private static let sidebarWidth: CGFloat = 224
    private var sidebarMinHeight: CGFloat = 0
    private var sidebarStack = NSStackView()

    private let tools = NSSegmentedControl()
    private let colors = NSSegmentedControl()
    private let strokes = NSSegmentedControl()
    private let beautifyButton = NSButton()

    private var swatchButtons: [NSButton] = []
    private let padding = NSSlider(value: 0, minValue: 0, maxValue: 160, target: nil, action: nil)
    private let corners = NSSlider(value: 0, minValue: 0, maxValue: 32, target: nil, action: nil)
    private let shadowToggle = NSButton(checkboxWithTitle: "Shadow", target: nil, action: nil)
    private let aspect = NSPopUpButton()
    private let balanceToggle = NSButton(checkboxWithTitle: "Balance margins", target: nil, action: nil)
    private var style: Beautify

    init(capture: Capture, annotations: [Annotation] = []) {
        self.capture = capture
        style = Settings.beautify

        // Size the window so the screenshot plus some workspace fits on screen.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        let available = screen.visibleFrame.size
        let sidebarWidth = style.enabled ? Self.sidebarWidth : 0
        let maxCanvas = CGSize(width: available.width * 0.85 - sidebarWidth, height: available.height * 0.85 - 52)
        let m = CanvasView.margin(for: capture.pointSize)
        let size = CGSize(width: capture.pointSize.width + 2 * m, height: capture.pointSize.height + 2 * m)
        let zoom = min(1, maxCanvas.width / size.width, maxCanvas.height / size.height)
        let canvasSize = CGSize(width: max(640, (size.width * zoom).rounded()), height: max(300, (size.height * zoom).rounded()))

        window = EditorWindow(contentRect: NSRect(origin: .zero, size: CGSize(width: canvasSize.width + sidebarWidth, height: canvasSize.height)),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Snap — \(capture.image.width) × \(capture.image.height)"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.appearance = NSAppearance(named: .darkAqua)

        canvas = CanvasView(capture: capture, style: style, annotations: annotations)
        canvas.frame = NSRect(origin: .zero, size: canvasSize)
        sidebar.frame = NSRect(x: canvasSize.width, y: 0, width: Self.sidebarWidth, height: canvasSize.height)
        sidebar.material = .sidebar
        sidebar.isHidden = !style.enabled

        super.init()

        let toolbar = NSToolbar(identifier: "SnapEditor")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        buildSidebar()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: canvasSize.width + sidebarWidth, height: canvasSize.height))
        canvas.autoresizingMask = [.height]
        sidebar.autoresizingMask = [.minXMargin, .height]
        root.addSubview(canvas)
        root.addSubview(sidebar)
        window.contentView = root
        // Adding the toolbar can change the content size; pin it to exactly canvas + sidebar.
        window.setContentSize(root.frame.size)
        // Measure the sidebar once it's in the window (controls only get their final size there), and
        // make the window tall enough that nothing gets cut off on small captures.
        root.layoutSubtreeIfNeeded()
        sidebarMinHeight = ceil(sidebarStack.fittingSize.height)
        if style.enabled, root.frame.height < sidebarMinHeight {
            window.setContentSize(NSSize(width: root.frame.width, height: sidebarMinHeight))
        }
        window.delegate = self
        window.controller = self
        canvas.onEscape = { [weak self] in self?.window.close() }
        canvas.onToolChange = { [weak self] in self?.syncToolbar() }
        syncToolbar()
        syncSidebar()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    // MARK: Actions

    func copyImage() {
        canvas.commitText()
        guard let png = export() else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(png, forType: .png)
        window.close()
    }

    func saveImage() {
        canvas.commitText()
        guard let png = export() else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "Screenshot \(formatter.string(from: Date()))"
        var url = Settings.saveFolder.appendingPathComponent("\(base).png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = Settings.saveFolder.appendingPathComponent("\(base) \(n).png")
            n += 1
        }
        do {
            try png.write(to: url)
            window.close()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func undo() { canvas.undo() }
    func redo() { canvas.redo() }
    func close() { window.close() }

    private func export() -> Data? {
        let data = Exporter.png(capture: capture, annotations: canvas.annotations, style: style, retina: Settings.retina)
        if data == nil { NSSound.beep() }
        return data
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    // MARK: Toolbar

    private enum Item {
        static let tools = NSToolbarItem.Identifier("tools")
        static let colors = NSToolbarItem.Identifier("colors")
        static let strokes = NSToolbarItem.Identifier("strokes")
        static let beautify = NSToolbarItem.Identifier("beautify")
        static let upscale = NSToolbarItem.Identifier("upscale")
        static let copy = NSToolbarItem.Identifier("copy")
        static let save = NSToolbarItem.Identifier("save")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Upscale only makes sense for captures from 1× screens; Retina captures are already 2×.
        [Item.tools, .space, Item.colors, .space, Item.strokes, .flexibleSpace]
            + (capture.scale < 2 ? [Item.upscale] : []) + [Item.beautify, .space, Item.copy, Item.save]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        let view: NSControl
        switch id {
        case Item.tools:
            tools.segmentCount = Tool.allCases.count
            tools.trackingMode = .selectOne
            for tool in Tool.allCases {
                tools.setImage(NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.label), forSegment: tool.rawValue)
                tools.setToolTip(tool.label, forSegment: tool.rawValue)
                tools.setWidth(32, forSegment: tool.rawValue)
            }
            tools.target = self
            tools.action = #selector(toolChanged)
            item.label = "Tools"
            view = tools
        case Item.colors:
            colors.segmentCount = Palette.colors.count
            colors.trackingMode = .selectOne
            for (i, color) in Palette.colors.enumerated() {
                colors.setImage(swatch(color), forSegment: i)
                colors.setToolTip("Color (\(i + 1))", forSegment: i)
                colors.setWidth(24, forSegment: i)
            }
            colors.target = self
            colors.action = #selector(colorChanged)
            item.label = "Color"
            view = colors
        case Item.strokes:
            strokes.segmentCount = Stroke.allCases.count
            strokes.trackingMode = .selectOne
            for stroke in Stroke.allCases {
                strokes.setImage(strokeIcon(stroke), forSegment: stroke.rawValue)
                strokes.setWidth(28, forSegment: stroke.rawValue)
            }
            strokes.setToolTip("Thickness ([ and ])", forSegment: 0)
            strokes.target = self
            strokes.action = #selector(strokeChanged)
            item.label = "Thickness"
            view = strokes
        case Item.beautify:
            beautifyButton.bezelStyle = .toolbar
            beautifyButton.setButtonType(.pushOnPushOff)
            beautifyButton.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Beautify")
            beautifyButton.toolTip = "Beautify: background, padding, corners, shadow"
            beautifyButton.state = style.enabled ? .on : .off
            beautifyButton.target = self
            beautifyButton.action = #selector(beautifyToggled)
            item.label = "Beautify"
            view = beautifyButton
        case Item.upscale:
            let button = NSButton(title: "Upscale 2×", target: self, action: #selector(upscaleClicked(_:)))
            button.bezelStyle = .toolbar
            button.toolTip = "Sharpen this low-resolution capture to 2× with on-device AI"
            item.label = "Upscale"
            view = button
        case Item.copy:
            let button = NSButton(title: "Copy", target: self, action: #selector(copyClicked))
            button.bezelStyle = .toolbar
            button.toolTip = "Copy to clipboard (⌘C)"
            item.label = "Copy"
            view = button
        case Item.save:
            let button = NSButton(title: "Save", target: self, action: #selector(saveClicked))
            button.bezelStyle = .toolbar
            button.toolTip = "Save to \(Settings.saveFolder.lastPathComponent) (⌘S)"
            item.label = "Save"
            view = button
        default:
            return nil
        }
        view.refusesFirstResponder = true
        item.view = view
        return item
    }

    private func syncToolbar() {
        tools.selectedSegment = canvas.tool.rawValue
        colors.selectedSegment = canvas.colorIndex
        strokes.selectedSegment = canvas.stroke.rawValue
    }

    @objc private func toolChanged() { canvas.setTool(Tool(rawValue: tools.selectedSegment) ?? .arrow) }
    @objc private func colorChanged() { canvas.setColor(colors.selectedSegment) }
    @objc private func strokeChanged() { canvas.setStroke(Stroke(rawValue: strokes.selectedSegment) ?? .medium) }
    @objc private func copyClicked() { copyImage() }

    @objc private func upscaleClicked(_ sender: NSButton) {
        sender.isEnabled = false
        sender.title = "Upscaling…"
        let image = capture.image
        Task.detached(priority: .userInitiated) {
            let result = Result { try Upscaler.upscale2x(image) }
            await MainActor.run {
                switch result {
                case .success(let upscaled):
                    // Same size in points, twice the pixels: marks and layout stay where they are.
                    self.capture = Capture(image: upscaled, scale: self.capture.scale * 2)
                    self.canvas.capture = self.capture
                    self.window.title = "Snap — \(upscaled.width) × \(upscaled.height)"
                    sender.title = "Upscaled 2×"
                case .failure(let error):
                    sender.isEnabled = true
                    sender.title = "Upscale 2×"
                    NSAlert(error: error).beginSheetModal(for: self.window)
                }
            }
        }
    }
    @objc private func saveClicked() { saveImage() }

    // MARK: Beautify sidebar

    private func buildSidebar() {
        func header(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: 11, weight: .semibold)
            field.textColor = .secondaryLabelColor
            return field
        }

        // Background swatches, 5 per row.
        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        for (i, bg) in Background.allCases.enumerated() {
            let button = NSButton(image: NSImage(), target: self, action: #selector(backgroundClicked(_:)))
            button.tag = i
            button.isBordered = false
            button.imageScaling = .scaleNone
            button.toolTip = bg.title
            button.refusesFirstResponder = true
            button.widthAnchor.constraint(equalToConstant: 30).isActive = true
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            swatchButtons.append(button)
        }
        for row in stride(from: 0, to: swatchButtons.count, by: 5) {
            grid.addRow(with: Array(swatchButtons[row..<min(row + 5, swatchButtons.count)]))
        }

        aspect.addItems(withTitles: Aspect.allCases.map(\.title))
        for control in [padding, corners, shadowToggle, aspect, balanceToggle] as [NSControl] {
            control.target = self
            control.action = #selector(styleChanged)
            control.refusesFirstResponder = true
        }
        balanceToggle.toolTip = "Even out uneven margins so the content is centered"

        let stack = NSStackView(views: [
            header("BACKGROUND"), grid,
            header("PADDING"), padding,
            header("CORNERS"), corners,
            header("ASPECT RATIO"), aspect,
            shadowToggle, balanceToggle,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        for view in [grid, padding, aspect] as [NSView] { stack.setCustomSpacing(16, after: view) }
        stack.setCustomSpacing(16, after: corners)
        stack.setCustomSpacing(10, after: shadowToggle)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        padding.widthAnchor.constraint(equalToConstant: Self.sidebarWidth - 32).isActive = true
        corners.widthAnchor.constraint(equalTo: padding.widthAnchor).isActive = true
        aspect.widthAnchor.constraint(equalTo: padding.widthAnchor).isActive = true

        sidebarStack = stack
        sidebar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: sidebar.topAnchor),
            stack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
        ])
    }

    private func syncSidebar() {
        for (i, button) in swatchButtons.enumerated() {
            let bg = Background.allCases[i]
            button.image = swatchImage(bg, selected: bg == style.background)
        }
        padding.doubleValue = style.padding
        corners.doubleValue = style.cornerRadius
        shadowToggle.state = style.shadow ? .on : .off
        aspect.selectItem(at: Aspect.allCases.firstIndex(of: style.aspect) ?? 0)
        balanceToggle.state = style.balance ? .on : .off
    }

    @objc private func backgroundClicked(_ sender: NSButton) {
        style.background = Background.allCases[sender.tag]
        apply()
    }

    @objc private func styleChanged() {
        style.padding = padding.doubleValue.rounded()
        style.cornerRadius = corners.doubleValue.rounded()
        style.shadow = shadowToggle.state == .on
        style.aspect = Aspect.allCases[max(0, aspect.indexOfSelectedItem)]
        style.balance = balanceToggle.state == .on
        apply()
    }

    @objc private func beautifyToggled() {
        style.enabled = beautifyButton.state == .on
        setSidebar(visible: style.enabled)
        apply()
    }

    private func apply() {
        Settings.beautify = style
        canvas.style = style
        syncSidebar()
        window.makeFirstResponder(canvas)
    }

    /// Grow/shrink the window to the right so the canvas keeps its size.
    private func setSidebar(visible: Bool) {
        guard sidebar.isHidden == visible else { return }
        let canvasWidth = canvas.frame.width
        var frame = window.frame
        frame.size.width += visible ? Self.sidebarWidth : -Self.sidebarWidth
        if visible, canvas.frame.height < sidebarMinHeight {
            let grow = sidebarMinHeight - canvas.frame.height
            frame.size.height += grow
            frame.origin.y -= grow // keep the top edge in place
        }
        sidebar.isHidden = !visible
        window.setFrame(frame, display: true, animate: true)
        canvas.frame.size.width = canvasWidth
        sidebar.frame = NSRect(x: canvasWidth, y: 0, width: Self.sidebarWidth, height: canvas.frame.height)
    }

    // MARK: Images

    private func swatchImage(_ bg: Background, selected: Bool) -> NSImage {
        let inner = bg.swatch(for: capture)
        return NSImage(size: NSSize(width: 30, height: 30), flipped: false) { rect in
            if selected {
                NSColor.controlAccentColor.setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
                ring.lineWidth = 2
                ring.stroke()
            }
            let size: CGFloat = bg == .auto || bg == .wallpaper ? 16 : 22
            let image = bg == .auto || bg == .wallpaper ? inner.tinted(.labelColor) : inner
            image.draw(in: NSRect(x: (rect.width - size) / 2, y: (rect.height - size) / 2, width: size, height: size))
            return true
        }
    }

    private func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            color.setFill()
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            circle.fill()
            NSColor.gray.withAlphaComponent(0.6).setStroke()
            circle.lineWidth = 1
            circle.stroke()
            return true
        }
    }

    private func strokeIcon(_ stroke: Stroke) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 14), flipped: false) { rect in
            NSColor.black.setFill()
            let h = [1.5, 3, 5][stroke.rawValue]
            NSBezierPath(roundedRect: NSRect(x: 1, y: (rect.height - h) / 2, width: 16, height: h), xRadius: h / 2, yRadius: h / 2).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

private extension NSImage {
    /// Template symbol drawn in a solid color (symbols inside a custom-drawn image don't auto-tint).
    func tinted(_ color: NSColor) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
