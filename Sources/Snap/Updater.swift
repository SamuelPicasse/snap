import AppKit

/// Minimal self-updater: compares the latest GitHub release with this version, downloads its zip,
/// installs it only if it's signed by our own team, and relaunches.
enum Updater {
    static let repo = "SamuelPicasse/snap"
    static let teamID = "UJN9G4KLA2"
    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        let tag_name: String
        let assets: [Asset]
    }

    /// `userInitiated` (menu item) also reports "up to date" and errors; the daily check stays silent.
    @MainActor static func check(userInitiated: Bool) async {
        do {
            let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
            let release = try JSONDecoder().decode(Release.self, from: try await URLSession.shared.data(from: url).0)
            let latest = String(release.tag_name.drop { $0 == "v" })
            guard latest.compare(current, options: .numeric) == .orderedDescending,
                  let zip = release.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
                if userInitiated { alert("Snap is up to date", "You have the latest version (\(current)).") }
                return
            }
            guard alert("Snap \(latest) is available", "You have \(current). Install it and restart Snap?", button: "Install") else { return }
            try await install(zip.browser_download_url)
        } catch {
            if userInitiated { alert("Couldn't check for updates", error.localizedDescription) }
        }
    }

    @MainActor private static func install(_ url: URL) async throws {
        let (download, _) = try await URLSession.shared.download(from: url)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snap-update-\(UUID().uuidString)")
        try run("/usr/bin/ditto", "-x", "-k", download.path, dir.path)
        let app = dir.appendingPathComponent("Snap.app")
        // Refuse anything not signed by our Developer ID (a hijacked release can't replace the app).
        try run("/usr/bin/codesign", "--verify", "--deep", "--strict",
                "-R=anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\"", app.path)
        _ = try FileManager.default.replaceItemAt(Bundle.main.bundleURL, withItemAt: app)
        // Relaunch after we've quit, so the new instance can claim the hotkey.
        try run("/bin/sh", "-c", "(sleep 1; /usr/bin/open \"$0\") >/dev/null 2>&1 &", Bundle.main.bundlePath)
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ args: String...) throws {
        let process = try Process.run(URL(fileURLWithPath: tool), arguments: args)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "Snap", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: tool).lastPathComponent) failed while updating."])
        }
    }

    @MainActor @discardableResult
    private static func alert(_ title: String, _ message: String, button: String? = nil) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let button {
            alert.addButton(withTitle: button)
            alert.addButton(withTitle: "Later")
        }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn && button != nil
    }
}
