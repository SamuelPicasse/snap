import AppKit
import ScreenCaptureKit

/// A frozen full-screen image of one display, taken when the hotkey fires.
struct ScreenShot {
    let screen: NSScreen
    let image: CGImage
    let scale: CGFloat
}

/// The selected area, at the display's native pixel resolution.
final class Capture {
    let image: CGImage
    let scale: CGFloat
    lazy var analysis = CaptureAnalysis(image: image, scale: scale)

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
    }

    var pointSize: CGSize { CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }
}

enum ScreenGrabber {
    /// Freezes every screen up front, so the overlay, menus and hover states are captured
    /// exactly as they looked when the hotkey was pressed.
    @MainActor
    static func grabAllScreens() async throws -> [ScreenShot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        // Start every display's capture at once, then collect: with several screens this keeps the
        // hotkey-to-overlay delay at one capture instead of one per screen.
        let pending = NSScreen.screens.compactMap { screen -> (NSScreen, CGFloat, Task<CGImage, Error>)? in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let id = screen.deviceDescription[key] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else { return nil }

            let scale = screen.backingScaleFactor
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * scale)
            config.height = Int(screen.frame.height * scale)
            config.captureResolution = .best
            config.showsCursor = false
            config.colorSpaceName = CGColorSpace.sRGB

            let filter = SCContentFilter(display: display, excludingWindows: [])
            return (screen, scale, Task { try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) })
        }
        var shots: [ScreenShot] = []
        for (screen, scale, task) in pending {
            shots.append(ScreenShot(screen: screen, image: try await task.value, scale: scale))
        }
        return shots
    }
}
