import AppKit

enum Icons {
    /// Menu bar glyph: a dashed selection with a mouse pointer, like the app icon. Template, so macOS
    /// tints it for light/dark menu bars. 18 pt — the same visual size as the system's own status icons.
    static let menuBar: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            // Dashed rounded square, traced from the middle of its top edge: one dash per corner and side.
            let r = NSRect(x: 1.5, y: 1.5, width: 11, height: 11), radius: CGFloat = 2.4
            let square = NSBezierPath()
            square.move(to: NSPoint(x: r.midX, y: r.minY))
            for (corner, next) in [((r.maxX, r.minY), (r.maxX, r.maxY)), ((r.maxX, r.maxY), (r.minX, r.maxY)),
                                   ((r.minX, r.maxY), (r.minX, r.minY)), ((r.minX, r.minY), (r.maxX, r.minY))] {
                square.appendArc(from: NSPoint(x: corner.0, y: corner.1), to: NSPoint(x: next.0, y: next.1), radius: radius)
            }
            square.close()
            let period = (4 * (r.width - 2 * radius) + 2 * .pi * radius) / 8, dash: CGFloat = 2.2
            square.setLineDash([dash, period - dash], count: 2, phase: dash / 2)
            square.lineWidth = 1.6
            square.lineCapStyle = .round
            square.stroke()

            // Pointer, with a gap cut out of the dashes around it.
            let pointer = NSBezierPath()
            let points: [(CGFloat, CGFloat)] = [(9.6, 7.4), (10.3, 14.2), (12.0, 12.8), (13.4, 15.4), (14.7, 14.8), (13.3, 12.3), (15.8, 11.9)]
            pointer.move(to: NSPoint(x: points[0].0, y: points[0].1))
            for p in points.dropFirst() { pointer.line(to: NSPoint(x: p.0, y: p.1)) }
            pointer.close()
            pointer.lineJoinStyle = .round
            NSGraphicsContext.current?.compositingOperation = .clear
            pointer.lineWidth = 3
            pointer.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            pointer.lineWidth = 0.8
            pointer.fill()
            pointer.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Snap"
        return image
    }()
}
