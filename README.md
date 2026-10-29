# Snap

Tiny macOS screenshot tool: ⌘⇧3 → drag an area → annotate → ⌘C copy / ⌘S save. See [PRD.md](PRD.md).

## Build & install

```bash
Scripts/bundle.sh --install
```

Builds `build/Snap.app`, signs it with your Apple Development identity (keeps the Screen Recording permission across rebuilds), copies it to `~/Applications` and launches it.

One-time setup:
1. System Settings → Keyboard → Keyboard Shortcuts → Screenshots → untick **Save picture of screen as a file** (⌘⇧3).
2. Press ⌘⇧3 once and allow Snap under Privacy & Security → Screen & System Audio Recording.

## Editor keys

| Key | Action |
|---|---|
| L / A / R / T / B | Line / Arrow / Box / Text / Redact |
| 1–6 | Red, yellow, green, blue, black, white |
| [ / ] | Thinner / thicker |
| Shift (while dragging) | 45° lines, square boxes |
| ⌘Z / ⌘⇧Z | Undo / redo |
| Click a mark | Select it; drag to move, 1–6 / [ ] to restyle, Esc to deselect |
| Delete | Remove the selected mark (or the last one) |
| ⌘C / ⌘S | Copy / save to the save folder, then close |
| Esc | Close (menu bar → Reopen Last Screenshot, or launch Snap again, brings it back with its marks) |

## Notes

- Output is a palette PNG via libimagequant (vendored static lib in `Vendor/`, GPL-3), or a regular PNG when it can't reach the quality floor (or "Lossless" is on). Retina images carry 144 dpi so they display at the right size.
- `Snap --compress in.png out.png [scale]` runs the exporter on an existing file (plain, no beautify).
- `open ~/Applications/Snap.app --args --open image.png [scale]` opens an existing image in the editor.
- App icon: `swift Scripts/make-icon.swift` regenerates `Resources/AppIcon.icns` (run `swift build -c release` first; drop a square 1024×1024 `Resources/AppIcon-source.png` to use your own artwork).
- To update the vendored lib: `brew upgrade libimagequant` and copy `libimagequant.a` + `libimagequant.h` into `Vendor/libimagequant/`.

## Sharing a build

```bash
Scripts/bundle.sh --release
```

Signs with the Developer ID certificate (hardened runtime), notarizes with Apple and writes `build/Snap.zip`. The recipient unzips, moves `Snap.app` to Applications and follows the one-time setup above. Needs Apple Silicon and macOS 14+.

Once per Mac, store notarization credentials (app-specific password from appleid.apple.com):

```bash
xcrun notarytool store-credentials snap-notary --apple-id <apple-id> --team-id M7CUSD4FD9
```
