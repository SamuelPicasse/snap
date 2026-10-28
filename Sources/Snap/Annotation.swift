import AppKit

/// One drawn mark. Coordinates are in image points with a top-left origin.
struct Annotation {
    var tool: Tool
    var start: CGPoint
    var end: CGPoint
    var color: NSColor
    var stroke: Stroke
    var text = ""

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// Area the mark covers once drawn, including stroke width, arrowhead and text size.
    var bounds: CGRect {
        let w = stroke.width
        switch tool {
        case .line, .box, .redact: return rect.insetBy(dx: -w, dy: -w)
        case .arrow: return rect.insetBy(dx: -Renderer.arrowHead(w), dy: -Renderer.arrowHead(w))
        case .text:
            let size = (text as NSString).size(withAttributes: Renderer.textAttributes(color: color, size: stroke.fontSize))
            return CGRect(origin: start, size: size).insetBy(dx: -2, dy: -2)
        }
    }

    var isEmpty: Bool {
        switch tool {
        case .text: return text.trimmingCharacters(in: .whitespaces).isEmpty
        case .line, .arrow: return hypot(end.x - start.x, end.y - start.y) < 3
        case .box, .redact: return rect.width < 3 || rect.height < 3
        }
    }
}

/// Draws a capture plus its annotations. Used for both the editor view and the exported image,
/// so what you see is exactly what gets copied or saved.
/// Expects a flipped context (top-left origin) where 1 unit = 1 image point.
enum Renderer {
    /// Fill behind marks drawn outside the screenshot.
    static let background = NSColor.white
    /// Breathing room around marks that stick out of the screenshot.
    static let padding: CGFloat = 12

    static func arrowHead(_ width: CGFloat) -> CGFloat { max(10, width * 4) }

    /// The exported area: the screenshot, grown to include any marks that stick out of it.
    static func exportBounds(_ capture: Capture, _ annotations: [Annotation]) -> CGRect {
        let image = CGRect(origin: .zero, size: capture.pointSize)
        var bounds = image
        for a in annotations where a.tool != .redact && !image.contains(a.bounds) {
            bounds = bounds.union(a.bounds.insetBy(dx: -padding, dy: -padding))
        }
        return bounds.integral
    }

    /// Background (only when marks stick out), screenshot and marks.
    static func drawComposite(_ capture: Capture, _ annotations: [Annotation], in ctx: CGContext) {
        let bounds = exportBounds(capture, annotations)
        if bounds != CGRect(origin: .zero, size: capture.pointSize) {
            ctx.setFillColor(background.cgColor)
            ctx.fill(bounds)
        }
        draw(capture, annotations, in: ctx)
    }

    static func draw(_ capture: Capture, _ annotations: [Annotation], in ctx: CGContext) {
        drawImage(capture.image, in: CGRect(origin: .zero, size: capture.pointSize), ctx: ctx)
        for annotation in annotations {
            draw(annotation, capture: capture, ctx: ctx)
        }
    }

    static func draw(_ a: Annotation, capture: Capture, ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.setLineWidth(a.stroke.width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch a.tool {
        case .line:
            ctx.move(to: a.start)
            ctx.addLine(to: a.end)
            ctx.strokePath()
        case .arrow:
            drawArrow(a, ctx: ctx)
        case .box:
            ctx.stroke(a.rect)
        case .text:
            drawText(a, ctx: ctx)
        case .redact:
            pixelate(a.rect, capture: capture, ctx: ctx)
        }
    }

    static func textAttributes(color: NSColor, size: CGFloat) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = (color.brightnessComponent > 0.6 ? NSColor.black : NSColor.white).withAlphaComponent(0.7)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = .zero
        return [.font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: color, .shadow: shadow]
    }

    private static func drawArrow(_ a: Annotation, ctx: CGContext) {
        let angle = atan2(a.end.y - a.start.y, a.end.x - a.start.x)
        let length = hypot(a.end.x - a.start.x, a.end.y - a.start.y)
        let head = min(arrowHead(a.stroke.width), length * 0.6)
        let spread: CGFloat = .pi / 7

        // Stop the shaft inside the head so the round cap doesn't poke out of the tip.
        let shaftEnd = CGPoint(x: a.end.x - cos(angle) * head * 0.7, y: a.end.y - sin(angle) * head * 0.7)
        ctx.move(to: a.start)
        ctx.addLine(to: shaftEnd)
        ctx.strokePath()

        ctx.move(to: a.end)
        ctx.addLine(to: CGPoint(x: a.end.x - head * cos(angle - spread), y: a.end.y - head * sin(angle - spread)))
        ctx.addLine(to: CGPoint(x: a.end.x - head * cos(angle + spread), y: a.end.y - head * sin(angle + spread)))
        ctx.closePath()
        ctx.fillPath()
    }

    private static func drawText(_ a: Annotation, ctx: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        (a.text as NSString).draw(at: a.start, withAttributes: textAttributes(color: a.color, size: a.stroke.fontSize))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Mosaic instead of blur: blur can be partially reversed, big blocks can't.
    private static func pixelate(_ rect: CGRect, capture: Capture, ctx: CGContext) {
        let s = capture.scale
        let bounds = CGRect(x: 0, y: 0, width: capture.image.width, height: capture.image.height)
        let pixels = CGRect(x: rect.minX * s, y: rect.minY * s, width: rect.width * s, height: rect.height * s)
            .integral.intersection(bounds)
        guard !pixels.isEmpty, let crop = capture.image.cropping(to: pixels) else { return }

        let block: CGFloat = 10
        let cols = max(1, Int((pixels.width / s / block).rounded(.up)))
        let rows = max(1, Int((pixels.height / s / block).rounded(.up)))
        guard let small = CGContext(data: nil, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        small.interpolationQuality = .medium
        small.draw(crop, in: CGRect(x: 0, y: 0, width: cols, height: rows))
        guard let tiny = small.makeImage() else { return }

        ctx.interpolationQuality = .none
        drawImage(tiny, in: CGRect(x: pixels.minX / s, y: pixels.minY / s, width: pixels.width / s, height: pixels.height / s), ctx: ctx)
    }

    /// CGContext.draw assumes a bottom-left origin; flip locally so images aren't upside down.
    private static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }
}
