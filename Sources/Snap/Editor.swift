import AppKit

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
    /// Drawable workspace around the screenshot, in image points. Scales with the capture, so a
    /// small screenshot isn't lost in a sea of gray.
    static func margin(for size: CGSize) -> CGFloat { min(100, max(32, min(size.width, size.height) * 0.4)) }

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
    /// Selected mark (click on it), and the drag that moves it.
    private var selected: Int?
    private var move: (start: CGPoint, original: Annotation, moved: Bool)?

    /// Image coordinates → view: view = image * zoom + offset. Recomputed on every draw so the whole
    /// export (which grows with padding, aspect ratio and outside marks) always fits in view.
    private var zoom: CGFloat = 1
    private var offset: CGPoint = .zero
    private var visibleArea: CGRect = .zero

    init(capture: Capture, style: Beautify, annotations: [Annotation] = []) {
        self.capture = capture
        self.style = style
        self.annotations = annotations
        super.init(frame: .zero)
    }

    private func updateTransform() {
        let size = capture.pointSize, m = Self.margin(for: size)
        // Committed marks only, so the view doesn't rescale under the cursor mid-drag.
        let export = Renderer.layout(capture, annotations, style).canvas
        let area = CGRect(x: -m, y: -m, width: size.width + 2 * m, height: size.height + 2 * m)
            .union(export.insetBy(dx: -16, dy: -16))
        visibleArea = area
        // Up to 2× for small captures, so they're comfortable to draw on.
        zoom = min(2, bounds.width / area.width, bounds.height / area.height)
        offset = CGPoint(x: (bounds.width - area.width * zoom) / 2 - area.minX * zoom,
                         y: (bounds.height - area.height * zoom) / 2 - area.minY * zoom)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        // Open hand over a mark you can grab.
        if hitIndex(imagePoint(event)) != nil { NSCursor.openHand.set() } else { (tool == .text ? NSCursor.iBeam : .crosshair).set() }
    }

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

        if let i = selected, i < annotations.count {
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.5 / zoom)
            ctx.setLineDash(phase: 0, lengths: [4 / zoom, 3 / zoom])
            ctx.stroke(annotations[i].bounds.insetBy(dx: -4 / zoom, dy: -4 / zoom))
        }
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
        editSelected { $0.color = Palette.colors[index] }
        textField?.textColor = color
        onToolChange?()
    }

    func setStroke(_ stroke: Stroke) {
        self.stroke = stroke
        Settings.stroke = stroke
        editSelected { $0.stroke = stroke }
        textField?.font = .systemFont(ofSize: stroke.fontSize * zoom, weight: .bold)
        onToolChange?()
    }

    /// Recolor/resize the selected mark when you pick a color or thickness.
    private func editSelected(_ change: (inout Annotation) -> Void) {
        guard let i = selected, i < annotations.count else { return }
        undoStack.append(annotations)
        redoStack.removeAll()
        change(&annotations[i])
        needsDisplay = true
    }

    private func hitIndex(_ p: CGPoint) -> Int? {
        annotations.indices.reversed().first { annotations[$0].hit(p, tolerance: 5 / zoom) }
    }

    // MARK: Undo

    private func push(_ annotation: Annotation) {
        undoStack.append(annotations)
        redoStack.removeAll()
        annotations.append(annotation)
        needsDisplay = true
    }

    func undo() {
        selected = nil
        guard let previous = undoStack.popLast() else { return NSSound.beep() }
        redoStack.append(annotations)
        annotations = previous
        needsDisplay = true
    }

    func redo() {
        selected = nil
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
        // Clicking a mark selects it (drag to move, Delete to remove) instead of drawing over it.
        if let i = hitIndex(p) {
            selected = i
            move = (p, annotations[i], false)
            NSCursor.closedHand.set()
            needsDisplay = true
            return
        }
        if selected != nil {
            selected = nil
            needsDisplay = true
        }
        if tool == .text {
            beginText(at: p)
        } else {
            current = Annotation(tool: tool, start: p, end: p, color: color, stroke: stroke)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let m = move, let i = selected {
            if !m.moved {
                undoStack.append(annotations)
                redoStack.removeAll()
                move?.moved = true
            }
            let p = imagePoint(event)
            annotations[i] = m.original.moved(by: p.x - m.start.x, p.y - m.start.y)
            needsDisplay = true
            return
        }
        guard var a = current else { return }
        a.end = constrained(from: a.start, to: imagePoint(event), shift: event.modifierFlags.contains(.shift), tool: a.tool)
        current = a
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if move != nil {
            move = nil
            NSCursor.openHand.set()
            return
        }
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

        if event.keyCode == 53 { // Esc: deselect first, close second
            if selected != nil {
                selected = nil
                needsDisplay = true
                return
            }
            return onEscape?() ?? ()
        }
        if event.keyCode == 51 || event.keyCode == 117 { // Delete: remove selected mark, else the last one
            guard !annotations.isEmpty else { return NSSound.beep() }
            undoStack.append(annotations)
            redoStack.removeAll()
            annotations.remove(at: selected.map { min($0, annotations.count - 1) } ?? annotations.count - 1)
            selected = nil
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
