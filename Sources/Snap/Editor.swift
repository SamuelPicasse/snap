import AppKit

@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let capture: Capture
    private let window: EditorWindow
    private let canvas: CanvasView
    private let tools = NSSegmentedControl()
    private let colors = NSSegmentedControl()
    private let strokes = NSSegmentedControl()
    private let beautifyToggle = NSButton(checkboxWithTitle: "Beautify", target: nil, action: nil)
    private let backgrounds = NSSegmentedControl()
    private let padding = NSSlider(value: 0, minValue: 0, maxValue: 160, target: nil, action: nil)
    private let corners = NSSlider(value: 0, minValue: 0, maxValue: 32, target: nil, action: nil)
    private let shadowToggle = NSButton(checkboxWithTitle: "Shadow", target: nil, action: nil)
    private let aspect = NSPopUpButton()
    private let balanceToggle = NSButton(checkboxWithTitle: "Balance", target: nil, action: nil)
    private var beautifyControls: [NSControl] { [backgrounds, padding, corners, shadowToggle, aspect, balanceToggle] }

    init(capture: Capture) {
        self.capture = capture

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        let toolbarHeight: CGFloat = 80
        let available = screen.visibleFrame.size
        let maxCanvas = CGSize(width: available.width * 0.85, height: available.height * 0.85 - toolbarHeight - 28)
        let m = CanvasView.margin
        let size = CGSize(width: capture.pointSize.width + 2 * m, height: capture.pointSize.height + 2 * m)
        let zoom = min(1, maxCanvas.width / size.width, maxCanvas.height / size.height)
        let canvasSize = CGSize(width: (size.width * zoom).rounded(), height: (size.height * zoom).rounded())

        let content = CGSize(width: max(canvasSize.width + 24, 640), height: max(canvasSize.height + 24, 160) + toolbarHeight)
        window = EditorWindow(contentRect: NSRect(origin: .zero, size: content),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Snap — \(capture.image.width) × \(capture.image.height)"
        // Dark chrome around the image; without this the controls render in light mode on a dark background.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.13, alpha: 1)

        canvas = CanvasView(capture: capture, style: Settings.beautify)
        let area = content.height - toolbarHeight
        canvas.frame = NSRect(x: ((content.width - canvasSize.width) / 2).rounded(), y: ((area - canvasSize.height) / 2).rounded(),
                              width: canvasSize.width, height: canvasSize.height)

        super.init()

        // Widen the window if the toolbar doesn't fit (small captures), and re-center the canvas.
        let toolbar = makeToolbar()
        let width = max(content.width, ceil(toolbar.fittingSize.width))
        canvas.frame.origin.x = ((width - canvasSize.width) / 2).rounded()
        window.setContentSize(NSSize(width: width, height: content.height))

        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: content.height))
        root.addSubview(canvas)
        toolbar.frame = NSRect(x: 0, y: area, width: width, height: toolbarHeight)
        root.addSubview(toolbar)
        window.contentView = root
        window.delegate = self
        window.controller = self
        canvas.onEscape = { [weak self] in self?.window.close() }
        canvas.onToolChange = { [weak self] in self?.syncToolbar() }
        syncToolbar()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
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
        let url = Settings.saveFolder.appendingPathComponent("Screenshot \(formatter.string(from: Date())).png")
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
        let data = Exporter.png(capture: capture, annotations: canvas.annotations, style: canvas.style, retina: Settings.retina)
        if data == nil { NSSound.beep() }
        return data
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    // MARK: Toolbar

    private func makeToolbar() -> NSView {
        tools.segmentCount = Tool.allCases.count
        tools.trackingMode = .selectOne
        for tool in Tool.allCases {
            tools.setImage(NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.label), forSegment: tool.rawValue)
            tools.setToolTip(tool.label, forSegment: tool.rawValue)
            tools.setWidth(34, forSegment: tool.rawValue)
        }
        tools.target = self
        tools.action = #selector(toolChanged)

        colors.segmentCount = Palette.colors.count
        colors.trackingMode = .selectOne
        for (i, color) in Palette.colors.enumerated() {
            colors.setImage(swatch(color), forSegment: i)
            colors.setToolTip("Color (\(i + 1))", forSegment: i)
            colors.setWidth(26, forSegment: i)
        }
        colors.target = self
        colors.action = #selector(colorChanged)

        strokes.segmentCount = Stroke.allCases.count
        strokes.trackingMode = .selectOne
        for stroke in Stroke.allCases {
            strokes.setImage(strokeIcon(stroke), forSegment: stroke.rawValue)
            strokes.setWidth(30, forSegment: stroke.rawValue)
        }
        strokes.setToolTip("Thickness ([ and ])", forSegment: 0)
        strokes.target = self
        strokes.action = #selector(strokeChanged)

        let copy = NSButton(title: "Copy ⌘C", target: self, action: #selector(copyClicked))
        let save = NSButton(title: "Save ⌘S", target: self, action: #selector(saveClicked))
        save.keyEquivalent = ""

        for control in [tools, colors, strokes, copy, save] as [NSControl] { control.refusesFirstResponder = true }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let drawRow = NSStackView(views: [tools, colors, strokes, spacer, copy, save])
        drawRow.spacing = 12

        let stack = NSStackView(views: [drawRow, makeBeautifyRow()])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.autoresizingMask = [.width]
        drawRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -12).isActive = true
        return stack
    }

    private func makeBeautifyRow() -> NSView {
        backgrounds.segmentCount = Background.allCases.count
        backgrounds.trackingMode = .selectOne
        for (i, bg) in Background.allCases.enumerated() {
            backgrounds.setImage(bg.swatch(for: capture), forSegment: i)
            backgrounds.setToolTip(bg.title, forSegment: i)
            backgrounds.setWidth(26, forSegment: i)
        }
        padding.controlSize = .small
        corners.controlSize = .small
        padding.widthAnchor.constraint(equalToConstant: 80).isActive = true
        corners.widthAnchor.constraint(equalToConstant: 60).isActive = true
        aspect.addItems(withTitles: Aspect.allCases.map(\.title))
        aspect.controlSize = .small
        balanceToggle.toolTip = "Even out uneven margins so the content is centered"

        let style = canvas.style
        beautifyToggle.state = style.enabled ? .on : .off
        backgrounds.selectedSegment = Background.allCases.firstIndex(of: style.background) ?? 0
        padding.doubleValue = style.padding
        corners.doubleValue = style.cornerRadius
        shadowToggle.state = style.shadow ? .on : .off
        aspect.selectItem(at: Aspect.allCases.firstIndex(of: style.aspect) ?? 0)
        balanceToggle.state = style.balance ? .on : .off

        for control in [beautifyToggle] + beautifyControls {
            control.target = self
            control.action = #selector(styleChanged)
            control.refusesFirstResponder = true
        }
        beautifyControls.forEach { $0.isEnabled = style.enabled }

        func label(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: 11)
            field.textColor = .secondaryLabelColor
            return field
        }
        let row = NSStackView(views: [beautifyToggle, backgrounds, label("Padding"), padding, label("Corners"), corners,
                                      shadowToggle, aspect, balanceToggle])
        row.spacing = 10
        row.setCustomSpacing(4, after: row.views[2])
        row.setCustomSpacing(4, after: row.views[4])
        return row
    }

    @objc private func styleChanged() {
        let style = Beautify(enabled: beautifyToggle.state == .on,
                             background: Background.allCases[max(0, backgrounds.selectedSegment)],
                             padding: padding.doubleValue.rounded(),
                             cornerRadius: corners.doubleValue.rounded(),
                             shadow: shadowToggle.state == .on,
                             aspect: Aspect.allCases[max(0, aspect.indexOfSelectedItem)],
                             balance: balanceToggle.state == .on)
        beautifyControls.forEach { $0.isEnabled = style.enabled }
        Settings.beautify = style
        canvas.style = style
        window.makeFirstResponder(canvas)
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
    @objc private func saveClicked() { saveImage() }

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

/// Routes ⌘C/⌘S/⌘W/⌘Z to the editor (the app has no visible main menu to do it).
final class EditorWindow: NSWindow {
    weak var controller: EditorWindowController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), let controller else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": MainActor.assumeIsolated { controller.copyImage() }
        case "s": MainActor.assumeIsolated { controller.saveImage() }
        case "w": MainActor.assumeIsolated { controller.close() }
        case "z": MainActor.assumeIsolated { flags.contains(.shift) ? controller.redo() : controller.undo() }
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

final class CanvasView: NSView, NSTextFieldDelegate {
    /// Drawable workspace around the screenshot, in image points.
    static let margin: CGFloat = 100

    var onEscape: (() -> Void)?
    var onToolChange: (() -> Void)?
    private(set) var annotations: [Annotation] = []
    private(set) var tool = Settings.tool
    private(set) var colorIndex = Settings.colorIndex
    private(set) var stroke = Settings.stroke

    var style: Beautify { didSet { needsDisplay = true } }

    private let capture: Capture
    private var current: Annotation?
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private var textField: NSTextField?
    private var textOrigin: CGPoint = .zero

    /// Image coordinates → view: view = image * zoom + offset. Recomputed on every draw so the whole
    /// export (which grows with padding, aspect ratio and outside marks) always fits in view.
    private var zoom: CGFloat = 1
    private var offset: CGPoint = .zero
    private var visibleArea: CGRect = .zero

    init(capture: Capture, style: Beautify) {
        self.capture = capture
        self.style = style
        super.init(frame: .zero)
    }

    private func updateTransform() {
        let m = Self.margin, size = capture.pointSize
        // Committed marks only, so the view doesn't rescale under the cursor mid-drag.
        let export = Renderer.layout(capture, annotations, style).canvas
        let area = CGRect(x: -m, y: -m, width: size.width + 2 * m, height: size.height + 2 * m)
            .union(export.insetBy(dx: -16, dy: -16))
        visibleArea = area
        zoom = min(bounds.width / area.width, bounds.height / area.height)
        offset = CGPoint(x: (bounds.width - area.width * zoom) / 2 - area.minX * zoom,
                         y: (bounds.height - area.height * zoom) / 2 - area.minY * zoom)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: tool == .text ? .iBeam : .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        updateTransform()
        let marks = annotations + (current.map { [$0] } ?? [])

        // Workspace: slightly lighter than the window, so you can see where you can draw.
        ctx.setFillColor(NSColor(white: 0.19, alpha: 1).cgColor)
        ctx.fill(bounds)

        ctx.interpolationQuality = .high
        ctx.translateBy(x: offset.x, y: offset.y)
        ctx.scaleBy(x: zoom, y: zoom)
        // Shadow under exactly what will be exported, so it's clear what's included.
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 10, color: NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.setFillColor(Renderer.background.cgColor)
        ctx.fill(Renderer.layout(capture, marks, style).canvas)
        ctx.restoreGState()
        Renderer.drawFinal(capture, marks, style, in: ctx)
    }

    // MARK: Settings

    var color: NSColor { Palette.colors[colorIndex] }

    func setTool(_ tool: Tool) {
        commitText()
        self.tool = tool
        Settings.tool = tool
        window?.invalidateCursorRects(for: self)
        onToolChange?()
    }

    func setColor(_ index: Int) {
        colorIndex = index
        Settings.colorIndex = index
        textField?.textColor = color
        onToolChange?()
    }

    func setStroke(_ stroke: Stroke) {
        self.stroke = stroke
        Settings.stroke = stroke
        textField?.font = .systemFont(ofSize: stroke.fontSize * zoom, weight: .bold)
        onToolChange?()
    }

    // MARK: Undo

    private func push(_ annotation: Annotation) {
        undoStack.append(annotations)
        redoStack.removeAll()
        annotations.append(annotation)
        needsDisplay = true
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return NSSound.beep() }
        redoStack.append(annotations)
        annotations = previous
        needsDisplay = true
    }

    func redo() {
        guard let next = redoStack.popLast() else { return NSSound.beep() }
        undoStack.append(annotations)
        annotations = next
        needsDisplay = true
    }

    // MARK: Mouse

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        // Image coordinates; negative or beyond the image size when drawing in the workspace.
        let p = convert(event.locationInWindow, from: nil)
        let a = visibleArea
        return CGPoint(x: min(max((p.x - offset.x) / zoom, a.minX), a.maxX), y: min(max((p.y - offset.y) / zoom, a.minY), a.maxY))
    }

    override func mouseDown(with event: NSEvent) {
        commitText()
        let p = imagePoint(event)
        if tool == .text {
            beginText(at: p)
        } else {
            current = Annotation(tool: tool, start: p, end: p, color: color, stroke: stroke)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard var a = current else { return }
        a.end = constrained(from: a.start, to: imagePoint(event), shift: event.modifierFlags.contains(.shift), tool: a.tool)
        current = a
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let a = current else { return }
        current = nil
        if a.isEmpty { needsDisplay = true } else { push(a) }
    }

    /// Shift snaps lines/arrows to 45° steps and boxes to squares.
    private func constrained(from start: CGPoint, to end: CGPoint, shift: Bool, tool: Tool) -> CGPoint {
        guard shift else { return end }
        let dx = end.x - start.x, dy = end.y - start.y
        switch tool {
        case .line, .arrow:
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            let length = hypot(dx, dy)
            return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
        case .box, .redact:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        case .text:
            return end
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return super.keyDown(with: event) }

        if event.keyCode == 53 { return onEscape?() ?? () } // Esc
        if event.keyCode == 51 || event.keyCode == 117 { // Delete / Forward delete: remove last mark
            guard !annotations.isEmpty else { return NSSound.beep() }
            undoStack.append(annotations)
            redoStack.removeAll()
            annotations.removeLast()
            needsDisplay = true
            return
        }
        if let t = Tool.allCases.first(where: { $0.key == key }) { return setTool(t) }
        if let n = Int(key), (1...Palette.colors.count).contains(n) { return setColor(n - 1) }
        if key == "[" { return setStroke(Stroke(rawValue: max(0, stroke.rawValue - 1))!) }
        if key == "]" { return setStroke(Stroke(rawValue: min(2, stroke.rawValue + 1))!) }
        super.keyDown(with: event)
    }

    // MARK: Text

    private func beginText(at point: CGPoint) {
        textOrigin = point
        let field = NSTextField(string: "")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: stroke.fontSize * zoom, weight: .bold)
        field.textColor = color
        field.delegate = self
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        let height = ceil(stroke.fontSize * zoom * 1.4)
        // NSTextField insets its text ~2pt; shift left so the committed text lands where it was typed.
        let x = offset.x + point.x * zoom, y = offset.y + point.y * zoom
        field.frame = NSRect(x: x - 2, y: y, width: max(80, bounds.width - x), height: height)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
    }

    func commitText() {
        guard let field = textField else { return }
        textField = nil
        let text = field.stringValue
        field.delegate = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        let a = Annotation(tool: .text, start: textOrigin, end: textOrigin, color: color, stroke: stroke, text: text)
        if !a.isEmpty { push(a) }
    }

    private func cancelText() {
        guard let field = textField else { return }
        textField = nil
        field.delegate = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): commitText(); return true
        case #selector(NSResponder.cancelOperation(_:)): cancelText(); return true
        default: return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        commitText()
    }
}
