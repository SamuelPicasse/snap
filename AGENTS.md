# AGENTS.md

Guidance for coding agents (Claude Code, Codex, …) working in this repository. CLAUDE.md imports this file — edit only this one.

Snap is a tiny macOS menu bar screenshot tool (Swift + AppKit, no SwiftUI/web views, macOS 14+, Apple Silicon). Goal above all: as little code and as small/light an app as possible (~2 MB, ~13 MB idle memory). Prefer system frameworks over dependencies.

## Commands

```bash
swift build -c release                  # compile only
Scripts/bundle.sh                       # build/Snap.app (signed with Apple Development)
Scripts/bundle.sh --install             # + copy to ~/Applications and relaunch
Scripts/bundle.sh --release             # Developer ID + notarize + GitHub release + Homebrew cask (bump VERSION first)
.build/release/Snap --compress in.png out.png [scale]   # run the PNG exporter on a file
open build/Snap.app --args --open image.png [scale]     # open an image in the editor (scale 1 = shows Upscale 2×)
swift build -c release && swift Scripts/make-icon.swift # regenerate Resources/AppIcon.icns
```

There are no tests or linter. Verify exporter changes with `--compress`; verify UI by building and opening the app. Linker warnings about libimagequant objects "built for newer macOS" are expected.

## Architecture

- **Flow:** `AppDelegate` owns the status item, global hotkeys (`HotKey`, Carbon `RegisterEventHotKey`, one per `CaptureMode`), the menu, settings window, updater timer and the last screenshot. Hotkey → `ScreenGrabber.grabAllScreens()` freezes every display in parallel (ScreenCaptureKit) → `SelectionController` shows one `OverlayWindow` per screen (area: drag; screen: click the hovered screen) → `Capture` → `EditorWindowController`.
- **Coordinates:** a `Capture` is a pixel `CGImage` + `scale`. Annotations and layout are in **image points with a top-left origin**; `CanvasView` maps points ↔ view via `zoom`/`offset` recomputed each draw (fits the whole export). Upscale swaps in a 2× image with the same point size, so marks don't move.
- **Single renderer:** `Renderer` (in `Annotation.swift`) draws both the editor preview and the export: `layout()` computes content/canvas rects (marks outside the image grow the canvas; beautify adds padding/aspect), `drawFinal()` draws background, card, image and marks. Keep editor and export going through it.
- **Export:** `Exporter.png` renders at Retina or 1×, then quantizes with libimagequant (importance map favors the screenshot over the background, dithering only on the background) and writes the indexed PNG by hand (zlib via `Sources/CZlib`); truecolor ImageIO PNG is the fallback or used for "Lossless".
- **Settings:** `Settings` (UserDefaults; `Beautify` and shortcuts stored as JSON). `Tool`, `Stroke`, `Palette`, `CaptureMode` live in `Settings.swift`.
- **Upscaler:** `Resources/Upscaler.mlpackage` (Real-ESRGAN animevideov3, BSD-3, built by `Scripts/make-upscaler.py`) is compiled into the app by `bundle.sh`; `Upscaler` loads it per call and processes 512 px tiles to keep peak memory down.
- **Updater:** `Updater` checks `SamuelPicasse/snap` releases daily and from Settings, and installs a zip only if signed by team `UJN9G4KLA2`. The repo must stay public for this to work without auth.

## Gotchas

- libimagequant is a vendored static lib (`Vendor/libimagequant`, from Homebrew, GPL-3) linked via `Sources/CImageQuant/module.modulemap` and `-L` in `Package.swift`.
- Signing matters for Screen Recording permission: builds signed with a different identity than the installed app trigger a new permission prompt. Don't launch test builds that capture the screen on the user's Mac without asking.
- Never edit `Scripts/bundle.sh` while a `--release` is running (zsh reads scripts incrementally). Notarization uses keychain profile `snap-notary`; releases sign with Sammy's own team `UJN9G4KLA2`, not Picasse.
- Overlay windows must be `close()`d (with `isReleasedWhenClosed = false`), not just ordered out, or the frozen full-screen images leak.
- Global hotkeys need ⌘ or ⌃ (macOS 15+ rejects ⌥-only); the shortcut recorder handles ⌘ combos via `performKeyEquivalent`.
- Bundle id is `local.sammy.snap`; the Homebrew cask template is `Scripts/snap.rb`.
