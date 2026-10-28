import AppKit
import CoreImage

/// "Make it pretty" settings: the screenshot as a rounded card on a background.
struct Beautify: Codable, Equatable {
    var enabled = false
    var background: Background = .auto
    var padding: CGFloat = 48
    var cornerRadius: CGFloat = 10
    var shadow = true
    var aspect: Aspect = .free
    var balance = true
}

enum Aspect: String, Codable, CaseIterable {
    case free, wide, standard, square

    var title: String { ["Free", "16:9", "4:3", "1:1"][Self.allCases.firstIndex(of: self)!] }
    var ratio: CGFloat? { [nil, 16.0 / 9, 4.0 / 3, 1][Self.allCases.firstIndex(of: self)!] }
}

enum Background: String, Codable, CaseIterable {
    case auto, white, dark, wallpaper, sunset, ocean, grape, mint, night

    var title: String {
        switch self {
        case .auto: "Auto (from screenshot)"
        case .wallpaper: "Desktop wallpaper, blurred"
        default: rawValue.capitalized
        }
    }

    /// Mesh-style palette: [gradient start, gradient end, top-right glow, bottom-left glow].
    func colors(for capture: Capture) -> [NSColor]? {
        func hsb(_ h: CGFloat, _ s: CGFloat, _ b: CGFloat) -> NSColor {
            NSColor(hue: (h + 1).truncatingRemainder(dividingBy: 1), saturation: s, brightness: b, alpha: 1)
        }
        switch self {
        case .white: return [.white, .white, .white, .white]
        case .dark: return [hsb(0.62, 0.15, 0.16), hsb(0.62, 0.20, 0.10), hsb(0.62, 0.25, 0.24), hsb(0.75, 0.20, 0.18)]
        case .sunset: return [hsb(0.04, 0.60, 1.0), hsb(0.92, 0.55, 0.92), hsb(0.12, 0.55, 1.0), hsb(0.85, 0.45, 0.85)]
        case .ocean: return [hsb(0.55, 0.55, 0.95), hsb(0.62, 0.65, 0.80), hsb(0.48, 0.45, 1.0), hsb(0.68, 0.45, 0.85)]
        case .grape: return [hsb(0.75, 0.50, 0.90), hsb(0.65, 0.60, 0.80), hsb(0.88, 0.40, 1.0), hsb(0.60, 0.45, 0.90)]
        case .mint: return [hsb(0.40, 0.40, 0.92), hsb(0.50, 0.50, 0.80), hsb(0.30, 0.35, 1.0), hsb(0.55, 0.40, 0.90)]
        case .night: return [hsb(0.68, 0.60, 0.30), hsb(0.75, 0.55, 0.18), hsb(0.58, 0.60, 0.45), hsb(0.85, 0.50, 0.35)]
        case .auto:
            // Harmonize with the screenshot: take its edge color's hue (calm blue for gray UIs),
            // keep it soft, and go dark for dark screenshots.
            var (h, s, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            (capture.analysis.edgeColor.usingColorSpace(.sRGB) ?? .gray).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            let hue = s < 0.12 ? 0.62 : h
            if b < 0.35 {
                return [hsb(hue, 0.45, 0.32), hsb(hue + 0.08, 0.50, 0.20), hsb(hue - 0.06, 0.45, 0.45), hsb(hue + 0.15, 0.40, 0.30)]
            }
            return [hsb(hue, 0.35, 0.95), hsb(hue + 0.08, 0.45, 0.82), hsb(hue - 0.06, 0.28, 1.0), hsb(hue + 0.15, 0.35, 0.88)]
        case .wallpaper:
            return nil
        }
    }

    func draw(in rect: CGRect, capture: Capture, ctx: CGContext) {
        if self == .wallpaper, let image = Wallpaper.blurred {
            ctx.saveGState()
            ctx.clip(to: rect)
            // Aspect-fill.
            let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            ctx.translateBy(x: rect.midX - size.width / 2, y: rect.midY + size.height / 2)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(origin: .zero, size: size))
            ctx.restoreGState()
            return
        }

        let c = (colors(for: capture) ?? Background.auto.colors(for: capture)!).map(\.cgColor)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        ctx.saveGState()
        ctx.clip(to: rect)
        let base = CGGradient(colorsSpace: space, colors: [c[0], c[1]] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(base, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
        // Two soft glows give the "mesh" look.
        let radius = max(rect.width, rect.height) * 0.75
        for (color, center) in [(c[2], CGPoint(x: rect.maxX, y: rect.minY)), (c[3], CGPoint(x: rect.minX, y: rect.maxY))] {
            let glow = CGGradient(colorsSpace: space, colors: [color, color.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }
        ctx.restoreGState()
    }

    /// Small round preview for the toolbar.
    func swatch(for capture: Capture) -> NSImage {
        if self == .auto { return NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: title)! }
        if self == .wallpaper { return NSImage(systemSymbolName: "photo", accessibilityDescription: title)! }
        return NSImage(size: NSSize(width: 16, height: 16), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let circle = CGPath(ellipseIn: rect.insetBy(dx: 1, dy: 1), transform: nil)
            ctx.addPath(circle)
            ctx.clip()
            self.draw(in: rect, capture: capture, ctx: ctx)
            ctx.resetClip()
            ctx.addPath(circle)
            ctx.setStrokeColor(NSColor.gray.withAlphaComponent(0.6).cgColor)
            ctx.strokePath()
            return true
        }
    }
}

/// The current desktop picture, downscaled and blurred once.
enum Wallpaper {
    nonisolated(unsafe) private static var cache: CGImage??

    static var blurred: CGImage? {
        if let cache { return cache }
        let result = load()
        cache = .some(result)
        return result
    }

    private static func load() -> CGImage? {
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 800] as CFDictionary
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let input = CIImage(cgImage: thumb)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: 18).cropped(to: input.extent)
        return CIContext().createCGImage(blurred, from: input.extent)
    }
}

/// Measured once per capture, only when needed (balance or auto background).
struct CaptureAnalysis {
    /// The screenshot with uneven solid-color margins trimmed so they're equal on opposite sides (points).
    let balancedRect: CGRect
    /// Average color of the screenshot's outer edge.
    let edgeColor: NSColor

    init(image: CGImage, scale: CGFloat) {
        // Work at point resolution: precise enough, 4× less memory on Retina.
        let w = max(1, Int(CGFloat(image.width) / scale)), h = max(1, Int(CGFloat(image.height) / scale))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        // Rows in the buffer run top to bottom.
        func at(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * w + x) * 4
            return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
        }
        func same(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool { abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2) < 24 }
        func column(_ x: Int, _ ref: (Int, Int, Int)) -> Bool { stride(from: 0, to: h, by: 2).allSatisfy { same(at(x, $0), ref) } }
        func row(_ y: Int, _ ref: (Int, Int, Int)) -> Bool { stride(from: 0, to: w, by: 2).allSatisfy { same(at($0, y), ref) } }

        let maxX = Int(Double(w) * 0.4), maxY = Int(Double(h) * 0.4)
        let refLeft = at(0, h / 2), refRight = at(w - 1, h / 2), refTop = at(w / 2, 0), refBottom = at(w / 2, h - 1)
        var left = 0, right = 0, top = 0, bottom = 0
        while left < maxX, column(left, refLeft) { left += 1 }
        while right < maxX, column(w - 1 - right, refRight) { right += 1 }
        while top < maxY, row(top, refTop) { top += 1 }
        while bottom < maxY, row(h - 1 - bottom, refBottom) { bottom += 1 }

        // Only even out a pair when both sides are the same background (e.g. page whitespace);
        // otherwise a title bar or toolbar would be mistaken for a margin and cut off.
        let balanceX = same(refLeft, refRight), balanceY = same(refTop, refBottom)
        let trimLeft = balanceX ? left - min(left, right) : 0, trimRight = balanceX ? right - min(left, right) : 0
        let trimTop = balanceY ? top - min(top, bottom) : 0, trimBottom = balanceY ? bottom - min(top, bottom) : 0
        balancedRect = CGRect(x: trimLeft, y: trimTop, width: w - trimLeft - trimRight, height: h - trimTop - trimBottom)

        var sum = (0, 0, 0), n = 0
        for x in stride(from: 0, to: w, by: 2) { for y in [0, h - 1] { let p = at(x, y); sum = (sum.0 + p.0, sum.1 + p.1, sum.2 + p.2); n += 1 } }
        for y in stride(from: 0, to: h, by: 2) { for x in [0, w - 1] { let p = at(x, y); sum = (sum.0 + p.0, sum.1 + p.1, sum.2 + p.2); n += 1 } }
        edgeColor = NSColor(srgbRed: CGFloat(sum.0) / CGFloat(n * 255), green: CGFloat(sum.1) / CGFloat(n * 255),
                            blue: CGFloat(sum.2) / CGFloat(n * 255), alpha: 1)
    }
}
