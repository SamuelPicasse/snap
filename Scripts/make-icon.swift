// Renders the app icon into Resources/AppIcon.icns.
// Usage: swift build -c release && swift Scripts/make-icon.swift
// Artwork: Resources/AppIcon-source.png if present (1024×1024, square, full-bleed — no rounded corners
// or shadow; this script adds the macOS shape, margin and shadow), else the built-in drawing below.
// Every size is palette-compressed with Snap's own exporter to keep the app small.
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources")
let source = NSImage(contentsOf: resources.appendingPathComponent("AppIcon-source.png"))

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

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    if let source {
        ctx.interpolationQuality = .high
        source.draw(in: tile)
        ctx.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
    // Background: soft white, slightly darker toward the bottom.
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    func c(_ w: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: w, green: w, blue: w, alpha: a) }
    let base = CGGradient(colorsSpace: space, colors: [c(0.99), c(0.93)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    let ink = c(0.16)
    let raised = { ctx.setShadow(offset: CGSize(width: 0, height: -5 * s), blur: 10 * s, color: c(0, 0.3)) }

    // Dashed selection: a rounded square traced from the middle of its top edge, so the dashes land
    // evenly, one on each corner and two along each side.
    let r = CGRect(x: 250, y: 312, width: 460, height: 460), radius: CGFloat = 60
    let dashes = CGMutablePath()
    dashes.move(to: CGPoint(x: r.midX, y: r.maxY))
    for (corner, next) in [((r.maxX, r.maxY), (r.maxX, r.minY)), ((r.maxX, r.minY), (r.minX, r.minY)),
                           ((r.minX, r.minY), (r.minX, r.maxY)), ((r.minX, r.maxY), (r.maxX, r.maxY))] {
        dashes.addArc(tangent1End: CGPoint(x: corner.0, y: corner.1), tangent2End: CGPoint(x: next.0, y: next.1), radius: radius)
    }
    dashes.closeSubpath()
    let period = (4 * (r.width - 2 * radius) + 2 * .pi * radius) / 12, dash: CGFloat = 70
    ctx.saveGState()
    raised()
    ctx.addPath(dashes)
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(40)
    ctx.setLineCap(.round)
    ctx.setLineDash(phase: dash + (period - dash) / 2, lengths: [dash, period - dash])
    ctx.strokePath()
    ctx.restoreGState()

    // Mouse pointer over the bottom-right corner, with a white edge where it crosses the dashes.
    let pointer = CGMutablePath()
    pointer.addLines(between: [(612, 520), (640, 780), (705, 725), (758, 812), (806, 788), (752, 700), (842, 686)]
        .map { CGPoint(x: $0.0, y: 1024 - $0.1) })
    pointer.closeSubpath()
    ctx.setLineJoin(.round)
    ctx.addPath(pointer)
    ctx.setStrokeColor(c(0.97))
    ctx.setLineWidth(64)
    ctx.strokePath()
    ctx.saveGState()
    raised()
    ctx.beginTransparencyLayer(auxiliaryInfo: nil) // one shadow for fill + rounded edge together
    ctx.addPath(pointer)
    ctx.setFillColor(ink)
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(28)
    ctx.drawPath(using: .fillStroke)
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func run(_ tool: String, _ args: [String]) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: tool)
    task.arguments = args
    task.standardOutput = FileHandle.nullDevice
    try! task.run()
    task.waitUntilExit()
    precondition(task.terminationStatus == 0, "\(tool) failed")
}

// Write the .icns directly (iconutil re-encodes the PNGs and more than doubles the size).
// Each entry: 4-byte type, 4-byte big-endian length (incl. header), PNG data.
let snap = root.appendingPathComponent(".build/release/Snap").path
precondition(FileManager.default.isExecutableFile(atPath: snap), "Build first: swift build -c release")
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("snap-icon.png").path
func be(_ v: Int) -> Data { Data([UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
var body = Data()
for (type, px) in [("icp4", 16), ("icp5", 32), ("ic11", 32), ("ic12", 64), ("ic07", 128),
                   ("ic13", 256), ("ic08", 256), ("ic14", 512), ("ic09", 512), ("ic10", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: tmp))
    run(snap, ["--compress", tmp, tmp, "1"])
    let png = try! Data(contentsOf: URL(fileURLWithPath: tmp))
    body += Data(type.utf8) + be(png.count + 8) + png
}
try! (Data("icns".utf8) + be(body.count + 8) + body).write(to: resources.appendingPathComponent("AppIcon.icns"))
print("Wrote Resources/AppIcon.icns")
