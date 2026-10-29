import AppKit

/// Shows a dimmed, frozen copy of every screen and lets the user drag out an area on one of them.
@MainActor
final class SelectionController {
    private var windows: [OverlayWindow] = []
    private let completion: (Capture?) -> Void
    private var finished = false

    init(shots: [ScreenShot], completion: @escaping (Capture?) -> Void) {
        self.completion = completion
        for shot in shots {
            let window = OverlayWindow(shot: shot)
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

    init(shot: ScreenShot) {
        overlay = OverlayView(shot: shot)
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
    private let frozen: NSImage
    private var start: NSPoint?
    private var selection: NSRect?

    init(shot: ScreenShot) {
        self.shot = shot
        frozen = NSImage(cgImage: shot.image, size: shot.screen.frame.size)
        super.init(frame: NSRect(origin: .zero, size: shot.screen.frame.size))
        // Multiple displays: make the screen under the mouse key, so Esc and the crosshair work there.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
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
        let text = "\(Int(rect.width * shot.scale)) × \(Int(rect.height * shot.scale))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        var box = NSRect(x: rect.maxX - size.width - 10, y: rect.minY - size.height - 10,
                         width: size.width + 10, height: size.height + 4)
        if box.minY < 4 { box.origin.y = rect.minY + 6 }
        box.origin.x = max(4, box.origin.x)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        text.draw(at: NSPoint(x: box.minX + 5, y: box.minY + 2), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
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
