# Rapid marker contacts and remaining audit work — 24 October 2026

## Scope and commits

Changes are kept in separate Conventional Commits on `dev`:

- Touched-tile ink snapshots replace the full-screen copy on each contact.
- Tight tile allocation avoids copying a viewport's parent stride. Repeated
  samples inside an already captured tile rectangle need no new snapshot work.
- Background/page snapshots retain only drawable content and explicit origins.
- Thumbnail loading validates the complete serialized document but creates
  Stroke objects only for the selected page.
- Brush modules are cached outside per-sample loops; no independent speedup is
  claimed for this small change.
- Broken PDF previews log a bounded warning and draw a clipped error marker;
  strict PDF export still fails, cleans partial output and preserves an existing
  destination. Native document/page handles and failed rasters are released.
- Native suspend fixtures now supply the actual stylus slot. Native ink checks
  tear down device input when finished.

This completes original backlog items 8, 9, 12 and 15, in addition to the nine
items completed in the preceding audit. It implements no ReaderUI annotations.

## Marker measurements

`tools/bench-marker-contact.lua` drives production Canvas methods on 12 nearby
marker strokes with 11 or 401 samples each, at 1x and 2x and widths 48/120.
It suppresses physical refreshes and checks final framebuffer bytes against an
independent authoritative repaint. The same fixture runs against v1.11.0-dev.1
and the current source in disposable Kindle storage.

One final paired run, mean wall milliseconds per short contact:

| Zoom | Width | Start, before → after | Total CPU-side wall time, before → after |
| --- | --- | --- | --- |
| 1x | 48 | 10.19 → 0.80 | 13.88 → 4.09 |
| 1x | 120 | 11.34 → 0.65 | 15.56 → 3.74 |
| 2x | 48 | 11.79 → 1.28 | 17.84 → 5.34 |
| 2x | 120 | 11.26 → 0.98 | 19.64 → 8.67 |

Long-contact totals in the same run were 39.78 → 34.33, 72.36 → 69.52,
65.14 → 60.68 and 124.92 → 125.06 ms respectively. Lift still rasterizes the
finished stroke: this change principally removes the expensive recontact copy.
Results vary between runs with device activity and JIT warm-up; these are
CPU-side measurements, not physical stylus-to-panel latency or refresh quality.

The initial viewport-copy experiment exposed native stride retention and was
replaced with tightly allocated buffers before publication. A dedicated native
regression verifies retained bytes and exact final pixels for edge contacts on
all four rotations, in BB8 and RGB32.

## Verification

- `make verify check-package`: 60 configured Lua suites, zero luacheck warnings
  or errors, translations, 16 Python tests, and package validation pass.
- Native feature/layout checks pass across all 13 shipped languages.
- `tools/check-native.py` versus v1.11.0-dev.1 passes 672 scaled-render
  comparisons, 29 preview/PDF-cache comparisons, 80 marker-geometry comparisons,
  and overlay/suspend checks at 1x/2x.
- Real Kindle offscreen BB8/RGB32 ink comparisons pass for colored pen, pencil,
  fountain and marker at 1x/2x, plus rotated edge-contact allocation checks.
- The thumbnail regression validates every page, rejects corruption on an
  unselected page, and reduces five materialized strokes to the selected two.
- PDF fault tests cover rendering, page/document close failures, clipped
  fallback pixels, warning deduplication, failed-thumbnail cache suppression,
  and strict export cleanup.
- Local native commands use `LUA_INIT="require('ffi').libc='gnu'"` with the
  existing compiled glibc runtime, as documented in the preceding audit. No
  sibling repository is modified.
- Raw logs, benchmark fixtures and generated images live in ignored
  `docs/audits/results/2026-10-24/`; no private notebooks are published.

## Deferred items and acceptance

1. The blanket `if not dirty then return true` save shortcut is still deferred:
   clean new notebooks, explicit saves, path changes and current-page metadata
   need an explicit persistence contract. Existing autosaves already check dirty
   state. A shortcut must not report success without creating a new file.
2. Replacing full e-ink reconciliation with a UI waveform is still deferred.
   Correct framebuffer pixels cannot establish panel ghosting or waveform
   quality. This change deliberately preserves the existing refresh policy.

The user should compare rapid short marker contacts at 1x against 2x on the
physical panel, then check long strokes, sleep/cover/resume, Undo/Redo and
reopening saved work. The current 800 ms idle color reconciliation can still
change the appearance after a rapid sequence. CPU improvements alone cannot
prove that every part of the reported display lag has disappeared.
