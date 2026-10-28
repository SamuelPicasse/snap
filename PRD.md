# PRD — Snap

A tiny personal macOS screenshot tool: hotkey → select area → annotate → copy or save. Sharp images, small files.

## Goals
- Replace the built-in ⌘⇧3 flow with capture → annotate → ⌘C / ⌘S in as few keystrokes as possible.
- Output that is crisp (readable text, clean lines) but small (target: typical area shot 100–400 KB).
- Lightweight: < 5 MB app, < 30 MB RAM idle, no background CPU.

## Non-goals (v1)
Window / full-screen capture, scrolling capture, recording/GIF, cloud upload, history, OCR, auto-update, distribution to others.

## Users
Just me. Local unsigned build, no notarization.

## Flow
1. Press **⌘⇧3** (the macOS default is disabled in System Settings → Keyboard → Keyboard Shortcuts → Screenshots).
2. Screen dims, crosshair appears on all displays. Drag a rectangle; size shown while dragging. **Esc** cancels.
3. On release, the **editor window** opens centered on screen, sized to fit the capture.
4. Annotate.
5. **⌘C** → copy to clipboard, close. **⌘S** → save to save folder, close. **Esc / ⌘W** → discard.

## Editor
| Tool | Key | Behavior |
|---|---|---|
| Line | L | Drag. Shift = snap to 0/45/90°. |
| Arrow | A | Like line, with arrowhead at the end. |
| Box | R | Outline rectangle. Shift = square. |
| Text | T | Click to place, type, Enter/click away to commit. |
| Redact | B | Drag a rectangle → pixelated (not Gaussian blur — blur can be reversed). |

- Colors: red (default), yellow, green, blue, black, white. Number keys 1–6.
- Stroke: thin / medium / thick. Scales with image so it looks the same at 1× and 2×.
- ⌘Z / ⌘⇧Z undo/redo. Select + Delete removes the last-clicked annotation (nice-to-have).
- Tool and color remembered between captures.

## Output
- **Resolution** (menu bar toggle): **Retina** (native, default) or **1×** (half width/height, high-quality downscale).
- **Format:** PNG, color-quantized (libimagequant, ~60–80% smaller with no visible change on UI screenshots). Falls back to plain PNG if the quantized version is not smaller. No JPEG.
- Same bytes go to the clipboard (`public.png`) and to disk.
- **Save folder:** ~/Downloads by default, changeable from the menu bar.
- **Filename:** `Screenshot 2026-10-28 at 14.32.05.png`.

## Menu bar
Capture · Resolution: Retina / 1× · Save folder… · Launch at login · Quit.

## Tech
- Swift + AppKit (no SwiftUI, no web views). Swift Package, built with `swift build`, wrapped in a .app bundle by a script.
- Capture: ScreenCaptureKit `SCScreenshotManager` (macOS 14+).
- Hotkey: Carbon `RegisterEventHotKey` (no dependency).
- Compression: libimagequant (GPL-3 — fine for personal use) + ImageIO PNG encoder.
- Permission: Screen Recording, requested on first capture.

## Edge cases
- Multiple displays with different scale factors: selection can't span displays (v1); capture uses that display's scale.
- Tiny selection (< 4 px) or click without drag → treated as cancel.
- Screen Recording permission missing → show explainer with a button to open System Settings.

## Decisions
1. Name: **Snap**.
2. Colors: the 6 presets above, red default. No custom picker.
3. Clipboard: image only (`public.png`), no file reference.

## Done when
⌘⇧3 → drag → draw an arrow + box + redact + text → ⌘C pastes a sharp, small image into Slack/Teams/Linear; ⌘S drops it in Downloads. Idle RAM < 30 MB.
