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
| Delete | Remove last mark |
| ⌘C / ⌘S | Copy / save to the save folder, then close |
| Esc | Discard |

## Notes

- Output is a palette PNG via libimagequant (vendored static lib in `Vendor/`, GPL-3) when smaller, else a regular PNG. Retina images carry 144 dpi so they display at the right size.
- `Snap --compress in.png out.png [scale]` runs the exporter on an existing file (writes `out.png` and `out@1x.png`).
- `open ~/Applications/Snap.app --args --open image.png [scale]` opens an existing image in the editor.
- App icon: `swift Scripts/make-icon.swift` regenerates `Resources/AppIcon.icns`.
- To update the vendored lib: `brew upgrade libimagequant` and copy `libimagequant.a` + `libimagequant.h` into `Vendor/libimagequant/`.
