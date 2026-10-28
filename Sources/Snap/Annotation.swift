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

    /// Whether a click at `p` grabs this mark. Lines and boxes only on their stroke, so you can still
    /// start drawing inside a box.
    func hit(_ p: CGPoint, tolerance t: CGFloat) -> Bool {
        let reach = stroke.width / 2 + t
        switch tool {
        case .line, .arrow:
            let d = CGPoint(x: end.x - start.x, y: end.y - start.y)
            let len2 = d.x * d.x + d.y * d.y
            let u = len2 == 0 ? 0 : max(0, min(1, ((p.x - start.x) * d.x + (p.y - start.y) * d.y) / len2))
            return hypot(p.x - (start.x + u * d.x), p.y - (start.y + u * d.y)) <= reach
        case .box:
            return rect.insetBy(dx: -reach, dy: -reach).contains(p) && !rect.insetBy(dx: reach, dy: reach).contains(p)
        case .redact, .text:
            return bounds.insetBy(dx: -t, dy: -t).contains(p)
        }
    }

    func moved(by dx: CGFloat, _ dy: CGFloat) -> Annotation {
        var a = self
        a.start = CGPoint(x: start.x + dx, y: start.y + dy)
        a.end = CGPoint(x: end.x + dx, y: end.y + dy)
        return a
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

    struct Layout {
        /// Screenshot (balanced if enabled) grown to include marks that stick out. The rounded card when beautifying.
        var content: CGRect
        /// The whole exported image: content plus beautify padding and aspect ratio.
        var canvas: CGRect
    }

    static func layout(_ capture: Capture, _ annotations: [Annotation], _ style: Beautify) -> Layout {
        let image = CGRect(origin: .zero, size: capture.pointSize)
        guard style.enabled else {
            let content = grown(image, by: annotations)
            return Layout(content: content, canvas: content)
        }
        let content = grown(style.balance ? capture.analysis.balancedRect : image, by: annotations)
        var canvas = content.insetBy(dx: -style.padding, dy: -style.padding)
        if let ratio = style.aspect.ratio {
            if canvas.width / canvas.height < ratio {
                canvas = canvas.insetBy(dx: -(canvas.height * ratio - canvas.width) / 2, dy: 0)
            } else {
                canvas = canvas.insetBy(dx: 0, dy: -(canvas.width / ratio - canvas.height) / 2)
            }
        }
        return Layout(content: content, canvas: canvas.integral)
    }

    /// `base`, grown to include any marks that stick out of it.
    private static func grown(_ base: CGRect, by annotations: [Annotation]) -> CGRect {
        var bounds = base
        for a in annotations where a.tool != .redact && !base.contains(a.bounds) {
            bounds = bounds.union(a.bounds.insetBy(dx: -padding, dy: -padding))
        }
        return bounds.integral
    }

    /// Everything that gets exported, in image coordinates: background, card shadow, screenshot and marks.
    static func drawFinal(_ capture: Capture, _ annotations: [Annotation], _ style: Beautify, in ctx: CGContext) {
        let layout = layout(capture, annotations, style)
        guard style.enabled else {
            if layout.content != CGRect(origin: .zero, size: capture.pointSize) {
                ctx.setFillColor(background.cgColor)
                ctx.fill(layout.content)
            }
            draw(capture, annotations, in: ctx)
            return
        }

        style.background.draw(in: layout.canvas, capture: capture, ctx: ctx)

        let radius = min(style.cornerRadius, layout.content.width / 2, layout.content.height / 2)
        let card = CGPath(roundedRect: layout.content, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if style.shadow {
            // Shadow params are in device pixels; scale them so the look is the same at any zoom/output scale.
            let s = abs(ctx.userSpaceToDeviceSpaceTransform.a)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -8 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.addPath(card)
            ctx.setFillColor(background.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(card)
        ctx.clip()
        ctx.setFillColor(background.cgColor)
        ctx.fill(layout.content)
        draw(capture, annotations, in: ctx)
        ctx.restoreGState()
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
