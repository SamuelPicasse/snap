import AppKit
import CImageQuant
import CZlib
import ImageIO
import UniformTypeIdentifiers

/// Renders the final image and encodes it as the smallest clean PNG:
/// a libimagequant palette PNG when it is smaller, otherwise a regular truecolor PNG.
enum Exporter {
    static func png(capture: Capture, annotations: [Annotation], retina: Bool) -> Data? {
        let outScale = retina ? capture.scale : 1
        let bounds = Renderer.exportBounds(capture, annotations)
        let width = Int((bounds.width * outScale).rounded())
        let height = Int((bounds.height * outScale).rounded())

        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: outScale, y: -outScale)
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        Renderer.drawComposite(capture, annotations, in: ctx)

        let rgba = Data(bytes: data, count: width * height * 4)
        let pixelsPerMeter = UInt32((72 * outScale / 0.0254).rounded())

        let truecolor = ctx.makeImage().flatMap { truecolorPNG($0, dpi: 72 * outScale) }
        let indexed = indexedPNG(rgba: rgba, width: width, height: height, pixelsPerMeter: pixelsPerMeter)
        switch (indexed, truecolor) {
        case let (i?, t?): return i.count < t.count ? i : t
        default: return indexed ?? truecolor
        }
    }

    // MARK: Truecolor (ImageIO)

    private static func truecolorPNG(_ image: CGImage, dpi: CGFloat) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let props = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
        CGImageDestinationAddImage(dest, image, props)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    // MARK: Palette (libimagequant + hand-written PNG)

    private static func indexedPNG(rgba: Data, width: Int, height: Int, pixelsPerMeter: UInt32) -> Data? {
        guard let attr = liq_attr_create() else { return nil }
        defer { liq_attr_destroy(attr) }
        // Min 70 / max 95: if it can't look near-identical with 256 colors, give up and use truecolor.
        liq_set_quality(attr, 70, 95)
        liq_set_speed(attr, 4)

        return rgba.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Data? in
            guard let image = liq_image_create_rgba(attr, buffer.baseAddress!, Int32(width), Int32(height), 0) else { return nil }
            defer { liq_image_destroy(image) }

            var result: OpaquePointer?
            guard liq_image_quantize(image, attr, &result) == LIQ_OK, let result else { return nil }
            defer { liq_result_destroy(result) }
            // Light dithering: smooth gradients without speckling text and UI edges.
            liq_set_dithering_level(result, 0.5)

            var indices = [UInt8](repeating: 0, count: width * height)
            guard liq_write_remapped_image(result, image, &indices, indices.count) == LIQ_OK,
                  let palettePointer = liq_get_palette(result) else { return nil }

            var palette = palettePointer.pointee
            let count = Int(palette.count)
            let colors = withUnsafeBytes(of: &palette.entries) { Array($0.bindMemory(to: liq_color.self).prefix(count)) }
            return encodeIndexed(width: width, height: height, indices: indices, palette: colors, pixelsPerMeter: pixelsPerMeter)
        }
    }

    private static func encodeIndexed(width: Int, height: Int, indices: [UInt8], palette: [liq_color], pixelsPerMeter: UInt32) -> Data? {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        var ihdr = Data()
        ihdr.appendBE(UInt32(width))
        ihdr.appendBE(UInt32(height))
        ihdr.append(contentsOf: [8, 3, 0, 0, 0]) // 8-bit, palette, deflate, no filter, no interlace
        png.appendChunk("IHDR", ihdr)
        png.appendChunk("sRGB", Data([0]))

        var phys = Data()
        phys.appendBE(pixelsPerMeter)
        phys.appendBE(pixelsPerMeter)
        phys.append(1) // unit: meter
        png.appendChunk("pHYs", phys)

        png.appendChunk("PLTE", Data(palette.flatMap { [$0.r, $0.g, $0.b] }))
        if let lastTransparent = palette.lastIndex(where: { $0.a < 255 }) {
            png.appendChunk("tRNS", Data(palette[...lastTransparent].map(\.a)))
        }

        // Each scanline is prefixed with filter type 0 (none) — best for palette images.
        var raw = Data(capacity: (width + 1) * height)
        for row in 0..<height {
            raw.append(0)
            raw.append(contentsOf: indices[(row * width)..<((row + 1) * width)])
        }
        guard let compressed = deflate(raw) else { return nil }
        png.appendChunk("IDAT", compressed)
        png.appendChunk("IEND", Data())
        return png
    }

    private static func deflate(_ input: Data) -> Data? {
        var length = compressBound(uLong(input.count))
        var output = Data(count: Int(length))
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                compress2(out.bindMemory(to: Bytef.self).baseAddress, &length,
                          inp.bindMemory(to: Bytef.self).baseAddress, uLong(input.count), 9)
            }
        }
        guard status == Z_OK else { return nil }
        output.count = Int(length)
        return output
    }
}

private extension Data {
    mutating func appendBE(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    mutating func appendChunk(_ type: String, _ body: Data) {
        appendBE(UInt32(body.count))
        let typeAndBody = Data(type.utf8) + body
        append(typeAndBody)
        let crc = typeAndBody.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(typeAndBody.count)) }
        appendBE(UInt32(crc))
    }
}
