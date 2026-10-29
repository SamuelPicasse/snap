import AppKit

// `Snap --compress in.png out.png [scale]`: run the exporter on an existing image (for testing).
let args = CommandLine.arguments
if args.count >= 4, args[1] == "--compress" {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        print("Can't read \(args[2])")
        exit(1)
    }
    let scale = args.count >= 5 ? CGFloat(Double(args[4]) ?? 2) : 2
    guard let png = MainActor.assumeIsolated({ Exporter.png(capture: Capture(image: image, scale: scale), annotations: [], style: Beautify(), retina: true) }),
          (try? png.write(to: URL(fileURLWithPath: args[3]))) != nil else { print("Export failed"); exit(1) }
    print("\(png.count / 1024) KB")
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
