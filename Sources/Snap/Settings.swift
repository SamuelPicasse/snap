import AppKit

enum Tool: Int, CaseIterable {
    case line, arrow, box, text, redact

    var key: String { ["l", "a", "r", "t", "b"][rawValue] }
    var symbol: String {
        ["line.diagonal", "arrow.up.right", "rectangle", "textformat", "checkerboard.rectangle"][rawValue]
    }
    var label: String { ["Line (L)", "Arrow (A)", "Box (R)", "Text (T)", "Redact (B)"][rawValue] }
}

enum Stroke: Int, CaseIterable {
    case thin, medium, thick

    /// Line width in image points, so it looks the same at Retina and 1× output.
    var width: CGFloat { [2, 4, 7][rawValue] }
    var fontSize: CGFloat { [14, 20, 28][rawValue] }
}

enum Palette {
    static let colors: [NSColor] = [
        NSColor(srgbRed: 0.95, green: 0.20, blue: 0.20, alpha: 1), // red
        NSColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1), // yellow
        NSColor(srgbRed: 0.20, green: 0.75, blue: 0.30, alpha: 1), // green
        NSColor(srgbRed: 0.15, green: 0.45, blue: 0.95, alpha: 1), // blue
        .black,
        .white,
    ]
}

/// UserDefaults-backed preferences.
enum Settings {
    private static let defaults = UserDefaults.standard

    static var retina: Bool {
        get { defaults.object(forKey: "retina") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "retina") }
    }

    static var saveFolder: URL {
        get {
            if let path = defaults.string(forKey: "saveFolder") { return URL(fileURLWithPath: path) }
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        set { defaults.set(newValue.path, forKey: "saveFolder") }
    }

    static var tool: Tool {
        get { Tool(rawValue: defaults.integer(forKey: "tool")) ?? .arrow }
        set { defaults.set(newValue.rawValue, forKey: "tool") }
    }

    static var colorIndex: Int {
        get { min(defaults.integer(forKey: "color"), Palette.colors.count - 1) }
        set { defaults.set(newValue, forKey: "color") }
    }

    static var beautify: Beautify {
        get { defaults.data(forKey: "beautify").flatMap { try? JSONDecoder().decode(Beautify.self, from: $0) } ?? Beautify() }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "beautify") }
    }

    static var stroke: Stroke {
        get { Stroke(rawValue: defaults.object(forKey: "stroke") as? Int ?? 1) ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: "stroke") }
    }
}
