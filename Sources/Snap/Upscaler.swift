import CoreImage
import CoreML

/// 2× AI upscale for screenshots from 1× screens (Real-ESRGAN animevideov3: crisp text, keeps gray tones).
/// The model is loaded only for the call and released right after, so idle memory stays unchanged.
/// Works in tiles so peak memory stays low even for a whole 1× screen.
enum Upscaler {
    static func upscale2x(_ image: CGImage) throws -> CGImage {
        guard let url = Bundle.main.url(forResource: "Upscaler", withExtension: "mlmodelc") else { throw failure("Upscaler model missing from the app.") }
        let model = try MLModel(contentsOf: url)
        let (w, h) = (image.width, image.height)
        guard let out = CGContext(data: nil, width: w * 2, height: h * 2, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw failure("Upscaling failed.") }
        let ci = CIContext(options: [.cacheIntermediates: false])
        let tile = 512, pad = 8 // overlap so tile edges don't show

        for y in stride(from: 0, to: h, by: tile) {
            for x in stride(from: 0, to: w, by: tile) {
                let inner = CGRect(x: x, y: y, width: min(tile, w - x), height: min(tile, h - y))
                let outer = inner.insetBy(dx: -CGFloat(pad), dy: -CGFloat(pad)).intersection(CGRect(x: 0, y: 0, width: w, height: h))
                guard let crop = image.cropping(to: outer) else { throw failure("Upscaling failed.") }
                let input = try MLFeatureValue(cgImage: crop, pixelsWide: crop.width, pixelsHigh: crop.height,
                                               pixelFormatType: kCVPixelFormatType_32BGRA, options: nil)
                guard let buffer = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": input]))
                    .featureValue(for: "output")?.imageBufferValue else { throw failure("Upscaling failed.") }

                // Model output is 4×; bring it to 2× and keep only the tile's own area (Core Image is bottom-up).
                let x2 = CIImage(cvPixelBuffer: buffer)
                    .applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": 0.5, "inputAspectRatio": 1.0])
                let keep = CGRect(x: (inner.minX - outer.minX) * 2, y: (outer.maxY - inner.maxY) * 2,
                                  width: inner.width * 2, height: inner.height * 2)
                guard let piece = ci.createCGImage(x2, from: keep) else { throw failure("Upscaling failed.") }
                out.draw(piece, in: CGRect(x: inner.minX * 2, y: (CGFloat(h) - inner.maxY) * 2, width: inner.width * 2, height: inner.height * 2))
            }
        }
        guard let result = out.makeImage() else { throw failure("Upscaling failed.") }
        return result
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Snap", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
