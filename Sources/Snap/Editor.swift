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
    private(set) var redactStyle = Settings.redactStyle

    var style: Beautify { didSet { needsDisplay = true } }

    var capture: Capture { didSet { needsDisplay = true } } // replaced by Upscale 2× (same point size)
    private var current: Annotation?
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private var textField: NSTextField?
    /// The text or callout being typed, and its index when editing an existing one (hidden meanwhile).
    private var editing: (mark: Annotation, index: Int?)?
    /// Selected mark (click on it), and the drag that moves it or one of its handles.
    private var selected: Int?
    private enum Drag { case move(from: CGPoint, original: Annotation), handle(end: Bool) }
    private var drag: (kind: Drag, changed: Bool)?

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
        var marks = annotations.indices.filter { $0 != editing?.index }.map { annotations[$0] } + (current.map { [$0] } ?? [])
        // A callout being typed shows its bubble and tail live; the text field sits on top.
        if var typing = editing?.mark, typing.tool == .callout, let field = textField {
            typing.text = field.stringValue
            marks.append(typing)
        }

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
            if annotations[i].tool.hasHandles {
                ctx.setLineDash(phase: 0, lengths: [])
                ctx.setFillColor(NSColor.white.cgColor)
                for p in [annotations[i].start, annotations[i].end] {
                    let r = 4 / zoom
                    ctx.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
                }
                ctx.drawPath(using: .fillStroke)
            }
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
        editing?.mark.color = color
        styleField()
        onToolChange?()
    }

    func setStroke(_ stroke: Stroke) {
        self.stroke = stroke
        Settings.stroke = stroke
        editSelected { $0.stroke = stroke }
        editing?.mark.stroke = stroke
        styleField()
        onToolChange?()
    }

    func setRedactStyle(_ style: RedactStyle) {
        redactStyle = style
        Settings.redactStyle = style
        if let i = selected, i < annotations.count, annotations[i].tool == .redact { editSelected { $0.redact = style } }
        onToolChange?()
    }

    /// Recolor/resize the selected mark when you pick a color or thickness.
    private func editSelected(_ change: (inout Annotation) -> Void) {
        guard let i = selected, i < annotations.count else { return }
        undoStack.append(annotations)
        redoStack.removeAll()
        change(&annotations[i])
        reattach()
        needsDisplay = true
    }

    private func hitIndex(_ p: CGPoint) -> Int? {
        annotations.indices.reversed().first { annotations[$0].hit(p, tolerance: 5 / zoom) }
    }

    // MARK: Attached arrows

    /// Attach the arrow's ends to the marks they were dropped on.
    private func attach(_ i: Int) {
        guard annotations[i].tool == .arrow else { return }
        func target(at p: CGPoint) -> Int? {
            annotations.indices.reversed().first { j in
                j != i && annotations[j].tool != .line && annotations[j].tool != .arrow
                    && annotations[j].targetRect.insetBy(dx: -6, dy: -6).contains(p)
            }.map { annotations[$0].id }
        }
        let a = annotations[i]
        annotations[i].startTarget = target(at: a.start)
        annotations[i].endTarget = target(at: a.end)
        if annotations[i].startTarget == annotations[i].endTarget { annotations[i].startTarget = nil }
        reattach()
    }

    /// Keep attached arrow ends on the edge of their target after it changed; let go of deleted targets.
    private func reattach() {
        let byID = Dictionary(annotations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for i in annotations.indices where annotations[i].tool == .arrow {
            var a = annotations[i]
            let s = a.startTarget.flatMap { byID[$0] }, e = a.endTarget.flatMap { byID[$0] }
            guard s != nil || e != nil || a.startTarget != nil || a.endTarget != nil else { continue }
            a.startTarget = s?.id
            a.endTarget = e?.id
            func center(_ t: Annotation) -> CGPoint { CGPoint(x: t.targetRect.midX, y: t.targetRect.midY) }
            let startFrom = e.map(center) ?? a.end, endFrom = s.map(center) ?? a.start
            if let s { a.start = s.anchor(from: startFrom) }
            if let e { a.end = e.anchor(from: endFrom) }
            annotations[i] = a
        }
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
        // Handles of the selected mark reshape it.
        if let i = selected, i < annotations.count, annotations[i].tool.hasHandles {
            let a = annotations[i]
            for (end, q) in [(false, a.start), (true, a.end)] where hypot(p.x - q.x, p.y - q.y) <= 7 / zoom {
                drag = (.handle(end: end), false)
                return
            }
        }
        // Clicking a mark selects it (drag to move, Delete to remove) instead of drawing over it.
        if let i = hitIndex(p) {
            if event.clickCount == 2, annotations[i].tool == .text || annotations[i].tool == .callout {
                selected = nil
                return beginText(annotations[i], index: i)
            }
            selected = i
            drag = (.move(from: p, original: annotations[i]), false)
            NSCursor.closedHand.set()
            needsDisplay = true
            return
        }
        if selected != nil {
            selected = nil
            needsDisplay = true
        }
        let mark = Annotation(tool: tool, start: p, end: p, color: color, stroke: stroke, redact: redactStyle)
        switch tool {
        case .text: beginText(mark, index: nil)
        case .step: push(mark)
        default: current = mark
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let d = drag, let i = selected {
            if !d.changed {
                undoStack.append(annotations)
                redoStack.removeAll()
                drag?.changed = true
            }
            let p = imagePoint(event)
            switch d.kind {
            case .move(let from, let original):
                var a = original.moved(by: p.x - from.x, p.y - from.y)
                if a.tool == .arrow { (a.startTarget, a.endTarget) = (nil, nil) }
                annotations[i] = a
            case .handle(let end):
                var a = annotations[i]
                let q = constrained(from: end ? a.start : a.end, to: p, shift: event.modifierFlags.contains(.shift), tool: a.tool)
                if end { (a.end, a.endTarget) = (q, nil) } else { (a.start, a.startTarget) = (q, nil) }
                annotations[i] = a
            }
            reattach()
            needsDisplay = true
            return
        }
        guard var a = current else { return }
        a.end = constrained(from: a.start, to: imagePoint(event), shift: event.modifierFlags.contains(.shift), tool: a.tool)
        current = a
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let d = drag {
            drag = nil
            if d.changed, let i = selected { attach(i) }
            if case .move = d.kind { NSCursor.openHand.set() }
            needsDisplay = true
            return
        }
        guard let a = current else { return }
        current = nil
        if a.tool == .callout { return beginText(a, index: nil) }
        if a.isEmpty { return needsDisplay = true }
        push(a)
        attach(annotations.count - 1)
    }

    /// Shift snaps lines/arrows to 45° steps and boxes to squares.
    private func constrained(from start: CGPoint, to end: CGPoint, shift: Bool, tool: Tool) -> CGPoint {
        guard shift else { return end }
        let dx = end.x - start.x, dy = end.y - start.y
        switch tool {
        case .line, .arrow, .callout:
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            let length = hypot(dx, dy)
            return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
        case .box, .redact, .spotlight:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        case .text, .step:
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
            reattach()
            selected = nil
            needsDisplay = true
            return
        }
        if let t = Tool.allCases.first(where: { $0.key == key }) { return setTool(t) }
        if tool == .redact, let n = Int(key), (1...RedactStyle.allCases.count).contains(n) { return setRedactStyle(RedactStyle(rawValue: n - 1)!) }
        if let n = Int(key), (1...Palette.colors.count).contains(n) { return setColor(n - 1) }
        if key == "[" { return setStroke(Stroke(rawValue: max(0, stroke.rawValue - 1))!) }
        if key == "]" { return setStroke(Stroke(rawValue: min(2, stroke.rawValue + 1))!) }
        super.keyDown(with: event)
    }

    // MARK: Text

    /// Type a new text or callout label, or edit an existing one (double-click) at `index`.
    private func beginText(_ mark: Annotation, index: Int?) {
        editing = (mark, index)
        let field = NSTextField(string: mark.text)
        field.isBordered = false
        field.focusRingType = .none
        field.delegate = self
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        addSubview(field)
        textField = field
        styleField()
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    /// Font, colors and frame of the text field, following the mark being typed.
    private func styleField() {
        guard let field = textField, let mark = editing?.mark else { return }
        let callout = mark.tool == .callout
        field.font = .systemFont(ofSize: mark.stroke.fontSize * zoom, weight: .bold)
        field.drawsBackground = callout
        field.backgroundColor = mark.color
        field.textColor = callout ? Renderer.ink(on: mark.color) : mark.color
        let pad = callout ? Renderer.calloutPadding(mark.stroke.fontSize) : .zero
        var typing = mark
        typing.text = field.stringValue
        let label = Renderer.calloutRect(typing)
        let origin = callout ? CGPoint(x: label.minX + pad.width, y: label.minY + pad.height) : mark.start
        let height = ceil(mark.stroke.fontSize * zoom * 1.4)
        // NSTextField insets its text ~2pt; shift left so the committed text lands where it was typed.
        let x = offset.x + origin.x * zoom, y = offset.y + origin.y * zoom
        let typed = (field.stringValue as NSString).size(withAttributes: [.font: field.font!]).width
        field.frame = NSRect(x: x - 2, y: y, width: callout ? max(40, ceil(typed) + 12) : max(80, bounds.width - x), height: height)
    }

    func commitText() {
        guard let field = textField, var mark = editing?.mark else { return }
        let index = editing?.index
        endText()
        mark.text = field.stringValue
        if let index {
            let old = annotations[index]
            guard mark.text != old.text || mark.color != old.color || mark.stroke != old.stroke else { return }
            undoStack.append(annotations)
            redoStack.removeAll()
            if mark.isEmpty { annotations.remove(at: index) } else { annotations[index] = mark }
            reattach()
        } else if !mark.isEmpty {
            push(mark)
        }
    }

    private func endText() {
        guard let field = textField else { return }
        textField = nil
        editing = nil
        field.delegate = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func controlTextDidChange(_ notification: Notification) {
        styleField()
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): commitText(); return true
        case #selector(NSResponder.cancelOperation(_:)): endText(); return true
        default: return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        commitText()
    }
}
