import AppKit

enum Icons {
    /// Menu bar glyph: viewfinder corners with an annotation arrow. Template, so macOS tints it
    /// for light/dark menu bars. 18 pt — the same visual size as the system's own status icons.
    static let menuBar: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            let corners = NSBezierPath()
            corners.lineWidth = 1.8
            corners.lineCapStyle = .round
            corners.lineJoinStyle = .round
            let (a, b, len): (CGFloat, CGFloat, CGFloat) = (1.9, 16.1, 4.6) // inset edges, bracket arm length
            for (x, y, dx, dy) in [(a, a, 1.0, 1.0), (b, a, -1.0, 1.0), (a, b, 1.0, -1.0), (b, b, -1.0, -1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
                corners.move(to: NSPoint(x: x + dx * len, y: y))
                corners.line(to: NSPoint(x: x + 0.8 * dx, y: y))
                corners.curve(to: NSPoint(x: x, y: y + 0.8 * dy), controlPoint1: NSPoint(x: x, y: y), controlPoint2: NSPoint(x: x, y: y))
                corners.line(to: NSPoint(x: x, y: y + dy * len))
            }
            corners.stroke()

            // Arrow from lower-left to upper-right, solid head.
            let shaft = NSBezierPath()
            shaft.lineWidth = 1.9
            shaft.lineCapStyle = .round
            shaft.move(to: NSPoint(x: 5.6, y: 12.4))
            shaft.line(to: NSPoint(x: 10.6, y: 7.4))
            shaft.stroke()
            let head = NSBezierPath()
            head.move(to: NSPoint(x: 12.9, y: 5.1))
            head.line(to: NSPoint(x: 12.4, y: 10.0))
            head.line(to: NSPoint(x: 8.0, y: 5.6))
            head.close()
            head.lineJoinStyle = .round
            head.lineWidth = 0.8
            head.fill()
            head.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Snap"
        return image
    }()
}
