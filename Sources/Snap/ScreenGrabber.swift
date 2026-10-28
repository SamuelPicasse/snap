import AppKit
import ScreenCaptureKit

/// A frozen full-screen image of one display, taken when the hotkey fires.
struct ScreenShot {
    let screen: NSScreen
    let image: CGImage
    let scale: CGFloat
}

/// The selected area, at the display's native pixel resolution.
struct Capture {
    let image: CGImage
    let scale: CGFloat

    var pointSize: CGSize { CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }
}

enum ScreenGrabber {
    /// Freezes every screen up front, so the overlay, menus and hover states are captured
    /// exactly as they looked when the hotkey was pressed.
    @MainActor
    static func grabAllScreens() async throws -> [ScreenShot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var shots: [ScreenShot] = []
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let id = screen.deviceDescription[key] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }

            let scale = screen.backingScaleFactor
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * scale)
            config.height = Int(screen.frame.height * scale)
            config.captureResolution = .best
            config.showsCursor = false
            config.colorSpaceName = CGColorSpace.sRGB

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            shots.append(ScreenShot(screen: screen, image: image, scale: scale))
        }
        return shots
    }
}
