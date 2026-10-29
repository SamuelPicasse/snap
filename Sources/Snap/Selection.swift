import AppKit

/// Shows a dimmed, frozen copy of every screen. Area mode: drag out an area on one of them.
/// Screen mode: the screen under the mouse lights up, a click captures all of it.
@MainActor
final class SelectionController {
    private var windows: [OverlayWindow] = []
    private let completion: (Capture?) -> Void
    private var finished = false

    init(shots: [ScreenShot], mode: CaptureMode, completion: @escaping (Capture?) -> Void) {
        self.completion = completion
        for shot in shots {
            let window = OverlayWindow(shot: shot, mode: mode)
            window.overlay.onFinish = { [weak self] capture in self?.finish(capture) }
            windows.append(window)
            window.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        (windows.first { $0.frame.contains(mouse) } ?? windows.first)?.makeKey()
    }

    private func finish(_ capture: Capture?) {
        guard !finished else { return }
        finished = true
        windows.forEach { $0.close() } // close, not orderOut: frees the window and its frozen screen image
        windows.removeAll()
        completion(capture)
    }
}

final class OverlayWindow: NSWindow {
    let overlay: OverlayView

    init(shot: ScreenShot, mode: CaptureMode) {
        overlay = OverlayView(shot: shot, mode: mode)
        super.init(contentRect: shot.screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(shot.screen.frame, display: false)
        isReleasedWhenClosed = false // ARC owns it
        level = .screenSaver
        isOpaque = true
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = overlay
        makeFirstResponder(overlay)
    }

    override var canBecomeKey: Bool { true }
}

final class OverlayView: NSView {
    var onFinish: ((Capture?) -> Void)?
    private let shot: ScreenShot
    private let mode: CaptureMode
    private let frozen: NSImage
    private var start: NSPoint?
    private var selection: NSRect?
    private var hovered: Bool

    init(shot: ScreenShot, mode: CaptureMode) {
        self.shot = shot
        self.mode = mode
        hovered = shot.screen.frame.contains(NSEvent.mouseLocation)
        frozen = NSImage(cgImage: shot.image, size: shot.screen.frame.size)
        super.init(frame: NSRect(origin: .zero, size: shot.screen.frame.size))
        // Multiple displays: make the screen under the mouse key, so Esc and the crosshair work there.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        frozen.draw(in: bounds)
        NSColor.black.withAlphaComponent(0.35).setFill()
        if mode == .screen {
            guard hovered else { return bounds.fill(using: .sourceOver) }
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
            border.lineWidth = 3
            border.stroke()
            drawPill("Click to capture this screen  ·  Esc to cancel", at: NSPoint(x: bounds.midX, y: bounds.midY))
            return
        }
        guard let selection else {
            bounds.fill(using: .sourceOver)
            return
        }

        let dim = NSBezierPath(rect: bounds)
        dim.append(NSBezierPath(rect: selection))
        dim.windingRule = .evenOdd
        dim.fill()

        NSColor.white.setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()

        drawSizeLabel(for: selection)
    }

    private func drawSizeLabel(for rect: NSRect) {
        let text = "\(Int(rect.width * shot.scale)) × \(Int(rect.height * shot.scale))"
        // Bottom-right under the selection, or inside it when there's no room below.
        let y = rect.minY < 30 ? rect.minY + 16 : rect.minY - 14
        drawPill(text, at: NSPoint(x: rect.maxX, y: y), alignRight: true)
    }

    private func drawPill(_ string: String, at point: NSPoint, alignRight: Bool = false) {
        let text = string as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        var box = NSRect(x: alignRight ? point.x - size.width - 10 : point.x - size.width / 2 - 5,
                         y: point.y - size.height / 2 - 2, width: size.width + 10, height: size.height + 4)
        box.origin.x = max(4, box.origin.x)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        text.draw(at: NSPoint(x: box.minX + 5, y: box.minY + 2), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        if mode == .screen { return onFinish?(Capture(image: shot.image, scale: shot.scale)) ?? () }
        start = convert(event.locationInWindow, from: nil)
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        var point = convert(event.locationInWindow, from: nil)
        point.x = min(max(point.x, 0), bounds.width)
        point.y = min(max(point.y, 0), bounds.height)
        selection = NSRect(x: min(start.x, point.x), y: min(start.y, point.y),
                           width: abs(point.x - start.x), height: abs(point.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .area else { return }
        defer { start = nil }
        guard let selection, selection.width * shot.scale >= 4, selection.height * shot.scale >= 4 else {
            onFinish?(nil)
            return
        }
        // CGImage origin is top-left; view origin is bottom-left.
        let pixels = CGRect(x: selection.minX * shot.scale,
                            y: (bounds.height - selection.maxY) * shot.scale,
                            width: selection.width * shot.scale,
                            height: selection.height * shot.scale).integral
        guard let cropped = shot.image.cropping(to: pixels) else {
            onFinish?(nil)
            return
        }
        onFinish?(Capture(image: cropped, scale: shot.scale))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) } else { super.keyDown(with: event) } // Esc
    }

    override func cancelOperation(_ sender: Any?) {
        onFinish?(nil)
    }
}
