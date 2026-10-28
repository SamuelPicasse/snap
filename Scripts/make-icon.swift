// Renders the app icon into Resources/AppIcon.icns.
// Usage: swift Scripts/make-icon.swift   (writes Resources/AppIcon.icns, needs iconutil)
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)

    // macOS icon grid: 824×824 rounded square centered in 1024, with a soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Background: indigo → violet with a warm glow, like the app's "Grape"/"Sunset" backgrounds.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    let base = CGGradient(colorsSpace: space, colors: [c(0.36, 0.30, 0.95), c(0.62, 0.25, 0.85)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
    for (color, center) in [(c(1.0, 0.45, 0.55), CGPoint(x: 924, y: 100)), (c(0.30, 0.65, 1.0), CGPoint(x: 100, y: 924))] {
        let glow = CGGradient(colorsSpace: space, colors: [color, color.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 620, options: [])
    }
    // Subtle top highlight.
    let shine = CGGradient(colorsSpace: space, colors: [c(1, 1, 1, 0.18), c(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(shine, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    // White viewfinder corners.
    ctx.setStrokeColor(c(1, 1, 1))
    ctx.setLineWidth(52)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let (a, b, len): (CGFloat, CGFloat, CGFloat) = (262, 762, 150)
    for (x, y, dx, dy) in [(a, a, 1.0, 1.0), (b, a, -1.0, 1.0), (a, b, 1.0, -1.0), (b, b, -1.0, -1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
        ctx.move(to: CGPoint(x: x + dx * len, y: y))
        ctx.addArc(tangent1End: CGPoint(x: x, y: y), tangent2End: CGPoint(x: x, y: y + dy * len), radius: 40)
        ctx.addLine(to: CGPoint(x: x, y: y + dy * len))
    }
    ctx.strokePath()

    // Coral annotation arrow, bottom-left → top-right, with a soft shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 14 * s, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil) // one shadow for shaft + head together
    let coral = c(1.0, 0.36, 0.33)
    ctx.setStrokeColor(coral)
    ctx.setFillColor(coral)
    ctx.setLineWidth(56)
    ctx.move(to: CGPoint(x: 372, y: 372))
    ctx.addLine(to: CGPoint(x: 590, y: 590))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 680, y: 680))
    ctx.addLine(to: CGPoint(x: 668, y: 500))
    ctx.addLine(to: CGPoint(x: 500, y: 668))
    ctx.closePath()
    ctx.setLineWidth(24)
    ctx.drawPath(using: .fillStroke)
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let resources = root.appendingPathComponent("Resources")
try! FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try! render(1024).write(to: resources.appendingPathComponent("AppIcon-preview.png"))
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
