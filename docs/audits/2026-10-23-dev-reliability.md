# Development integration and reliability review — 23 October 2026

## Scope

Merged stable `main` (v1.10.0) into `dev`, preserving development release
configuration. This work adds no ReaderUI PDF/EPUB annotation implementation;
`docs/READER_ANNOTATIONS.md` is the updated future integration plan.

The gallery density control now uses distinct 3-column/2-row and 4-column/3-row
SVG grids for the arrangement selected by the button. Both arrangements are
included in native offscreen layout checks.

## Audit backlog disposition

| Original item | Disposition |
| --- | --- |
| 1 — unconditional clean-save shortcut | Deferred. New files, explicit saves, and current-page metadata require a defined persistence contract before adding a generic `dirty` early return. |
| 2 — eraser autosave/undo notification | Implemented. Schedule after a changed batch commits; notify Undo after commit, including the shared zoom path. |
| 3 — lasso edit autosave | Implemented for cut, delete, paste and movement. Keep one debounced idle save and cancel drag callbacks separately. |
| 4 — replace full e-ink reconciliation | Deferred pending physical ghosting/waveform comparisons. |
| 5 — updater polling protection | Implemented with Safe protection at scheduled polling and completion entry points. |
| 6 — updater cleanup protection | Implemented; also protect scheduled weekly checks and manual network continuations. |
| 7 — empty thumbnail cache | Implemented using a bounded, persistent negative marker tied to source file identity/size/timestamps. Invalid entries and failed loads are retried. |
| 8 — selective thumbnail deserialization | Deferred. Bitser still reads the complete serialized object; avoiding all-page Stroke materialization needs a separately validated loader. |
| 9 — MuPDF drawing error recovery | Deferred. Logging alone could silently produce exports without their PDF backgrounds. Define display/export error propagation and handle cleanup together. |
| 10 — text dialog protection | Implemented with Safe.widget; regression dispatches a failing standalone editor event. |
| 11 — recent-menu nil guard | Implemented; missing reconstructed rows stop deferred preview work. |
| 12 — content-only bitmap snapshots | Deferred pending native memory measurements and coordinate/clipping tests. Existing snapshots have a byte budget. |
| 13 — incremental sharing PDF preparation | Implemented using Export.beginPDF and a scheduled step per export phase. Cache staging, output collisions and failure handling remain covered. XOPP export and file copies still run one item at a time. |
| 14 — progressive gallery thumbnails | Implemented: repaint every three successful renders and flush the final partial batch; generation cancellation and queue deduplication are preserved. |
| 15 — module-local brush requires | Deferred as an unmeasured micro-optimization; cached require calls are not module reloads. |

## Reproducible verification

- `make verify check-package`: lint reports zero warnings/errors; all configured
  Lua suites, translation checks, 16 Python benchmark-report tests and package
  validation pass. New suites: `thumbnailcache` and `gallerysharing`.
- Reproduced failures before production fixes for eraser/lasso persistence,
  stale recent-menu rows, standalone text-editor events, updater callbacks,
  incremental sharing, empty-thumbnail caching and progressive repainting.
- `python3 tools/test-native-features.py --all-languages --runtime <runtime>`:
  all shipped languages, portrait/landscape/device-size profiles and emulator
  scaling checks pass. Both gallery densities are rendered. The local compiled
  LuaJIT predates the current FFI sources' `ffi.libc` metadata; the test process
  uses `LUA_INIT="require('ffi').libc='gnu'"` on this glibc host. No sibling
  repository or compiled runtime was modified.
- `python3 tools/check-updater.py --ssh <device> --port 22 --ui`: real Kindle
  archiver/installer fixtures and offscreen Updates/page-selection layouts pass.
  Network release replacement was not requested by this check (`--network` is
  omitted). Test data lives in disposable device storage.
- Raw logs and generated screenshots remain outside version control.

## Physical acceptance still required

1. Write, erase, cut/delete, paste and move; pause, reopen, and confirm persisted
   results and one-step Undo/Redo, at 1x and 2x.
2. Exercise sleep button, magnetic cover, resume and closing Notebook during
   input; check for stale callbacks or ink over the cover.
3. Browse a real large library in both densities; observe thumbnail batching,
   empty-notebook invalidation and e-ink flashing/ghosting.
4. Share long/multiple notebooks through LocalSend, including failed transfers,
   PDF backgrounds and XOPP companions. Incremental scheduling does not make an
   individual render phase or file copy asynchronous.
5. Open the text keyboard, edit/cancel/commit and verify focus/palm behavior.

Offscreen rendering and headless tests do not establish physical stylus
latency, palm rejection, display waveform quality or a successful end-to-end
LocalSend transfer. Reader annotations remain future work.
