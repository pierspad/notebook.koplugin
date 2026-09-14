# Release polish — 14 September 2026

## Delivered

- Semantic-release on `dev` (prereleases) and `main` (stable), computed metadata version, tested ZIP attached to GitHub Releases. Stable history fast-forwards dev only when safe. No npm publishing. Dependencies pinned; compatible conventional-commits preset verified.
- Package checks no longer use a `grep -q` pipeline under `pipefail`: early pipe closure caused a false missing-file error on CI.
- PDF defaults crop the document's persisted content origin, translating ink and paper together. Explicit export areas remain authoritative. Native BB8 rows copy via FFI instead of per-pixel Lua conversion, including stride padding checks. Rendering failures preserve an existing destination using a temporary sibling and rename.
- Gallery selection sweeps intersect the entire drag segment, select each crossed card once, and reuse loaded thumbnails. Selection gestures do not page. Bulk deletion rebuilds the gallery once. Folder creation offers Work, Personal and current-month presets alongside a custom name.
- Pen-only object selections ignore finger touches and swipes, preventing a resting hand from dismissing a selection or changing its page.
- Private module loading isolates generic names from legacy Scribe and other plugins, including deferred callbacks. The legacy `scribe.koplugin` was moved out of the device plugin directory into `/mnt/us/koreader/cache/notebook-polish-20260914/legacy-scribe.koplugin`; notebooks were backed up separately.
- Pen hold menu has five distinct vector icons and two labelled groups. Clock sits between next-page and settings; settings align to the right. Clock updates pause while drawing and its timer is cancelled when the notebook closes.

## Verification

- Local `make ci`: lint, original regression suites, new export/gallery/module-isolation suites, installable ZIP validation.
- Kindle native smoke: actual widgets and fonts, pen menu, pressure/color serialization, arrow rendering and PDF generation. Offscreen output visually inspected.
- Pressure investigation: all four strokes in the user's saved test had pressure exactly 1. Two installed plugins shared module names, an interference risk now removed. A separate virtual-device listener received no samples. These findings do not prove physical pressure works after the change; a fresh stylus test after restart is still required.

## Deferred at user's request to ship the completed block

1. Confirm and, if needed, repair actual fountain pressure after removing legacy Scribe. Synthetic pressure rendering varies correctly; physical input still needs confirmation.
2. A throttled eraser outline, sharing the existing repaint budget and restoring the old outline without extra per-sample refreshes.
3. Conservative smoothing of held open curves, preserving intentional curvature and endpoints. No curve algorithm shipped in this release.
4. Highlighter dark-then-light live trail: current AUTO waveform performs panel transitions; changing a gray constant alone is not evidence that the hardware artifact disappears. Needs controlled on-device waveform tests.
5. Broader PDF/sharing/deletion benchmarks on large notebooks and folders. This release removes specific redundant work; no unmeasured speedup is claimed.
6. Confirm on the physical screen that no third-party/system clock overlay remains; native Notebook layout is verified.
