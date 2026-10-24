# Technical reference

This document describes the current architecture and the commands used to
verify changes. It complements the [user guide](USER_GUIDE.md), which covers
the interface and workflows. Reader annotations are a future integration plan,
not a current feature; see [READER_ANNOTATIONS.md](READER_ANNOTATIONS.md).

## Runtime architecture

The installable plugin is the contents of `lua/`. `main.lua` creates the
gallery and notebook screens; `loader.lua` loads the plugin's modules into an
isolated cache. KOReader APIs provide the screen, input, filesystem,
persistence, localization, and UI event loop.

The document is the source of truth. A document contains pages, each with
vector strokes, an optional paper template, and an optional PDF background.
Strokes store sampled page coordinates and pressure in compact flat arrays.
Text and image objects are represented as strokes with their own serialized
content and geometry. Undo and redo record document operations. Framebuffer
images are derived caches and are never saved as document state.

| Area | Main modules | Responsibility |
| --- | --- | --- |
| Document and storage | `document.lua`, `documenthistory.lua`, `documentformat.lua`, `documentstorage.lua` | Page model, undo/redo, validation, and atomic save/load |
| Canvas and lifecycle | `canvas.lua`, `canvaslifecycle.lua`, `viewcanvas.lua` | Screen ownership, page geometry, start/stop, pause/resume |
| Input | `stylusbridge.lua`, `stylusinput.lua`, `touchinput.lua`, `penpressure.lua` | Stylus routing, sample filtering, pressure, buttons, and touch gestures |
| Raster and paper | `renderer.lua`, `penink.lua`, `highlightink.lua`, `markerarea.lua`, `template.lua`, `pdfbackground.lua` | Stroke rendering, paper, PDF backgrounds, and clipping |
| Canvas mixins | `canvasrender.lua`, `canvasrefresh.lua`, `erasercanvas.lua`, `selectioncanvas.lua`, `shapecanvas.lua`, `snapcanvas.lua` | Painting, refresh scheduling, erasing, selection, shapes, and recognition |
| Zoom | `zoomcanvas.lua`, `zoomcache.lua`, `zoomrefresh.lua` | Enlarged page cache, viewport copies, and input/refresh coordination |
| Gallery and export | `gallery.lua`, `gallerythumbnails.lua`, `thumbnail.lua`, `export.lua`, `svg.lua`, `xopp.lua`, `share.lua` | Notebook browsing, previews, export, and optional LocalSend integration |
| Safety and settings | `safe.lua`, `tuning.lua`, `diagnostics.lua` | Protected callbacks, calibration settings, and opt-in diagnostics |

Canvas mixins are installed on the canvas prototype so high-frequency input
calls stay direct. Keep ownership of input handlers, scheduled callbacks, and
native blitbuffers explicit: each must have one clear start and cleanup path.
Register new private modules in the loader whitelist to avoid KOReader module
name collisions.

## Important invariants

- **Keep the vector document authoritative.** Page and zoom bitmaps are caches.
  Invalidate them when page content, paper, dimensions, PDF background, or
  display mode changes. Do not serialize transient previews or framebuffer data.
- **Use page coordinates consistently.** `content_origin` records the screen
  offset between the page and drawing area so thumbnails and exports align ink
  with paper. Clip direct raster writes and refresh rectangles to their owning
  viewport.
- **Treat live preview as temporary.** Colored ink may use a fast binary preview
  while the stylus moves. Restore its saved pixels before drawing final ink,
  then reconcile the dirty region only after contact is idle. Do not run slow
  waveforms underneath active input. `liveink.lua` captures touched 128-pixel
  tiles before preview writes, using tightly allocated buffers; copying a
  viewport with its parent stride can retain padding or overrun the last row.
- **Respect device-selected refresh behavior.** `refreshFast`, `refreshUI`,
  `refreshPartial`, and `refreshFull` map to device-specific waveforms.
  Their latency and flashing behavior differ by backend. Coalesce work and
  defer blocking updates until the canvas is at rest. Gray/color debt uses one
  clipped regional `refreshPartial` after the idle delay only when the backend
  explicitly identifies its partial waveform as REAGL. Other paths retain UI
  refresh. Preserve the manual full refresh; avoid a slow update per pen lift.
- **Own native resources and callbacks.** Free blitbuffers when caches are
  replaced or screens close. Unschedule callbacks during teardown, and never
  let a delayed canvas callback paint over a screen that covers it. Pause all
  direct framebuffer writers before a cover or suspend; finalize pending ink
  once after returning. Input wrappers must restore only hooks they own and
  preserve the device stylus slot.
- **Keep plugin failures contained.** `safe.lua` protects widget and scheduled
  entry points and restores temporary input hooks on failure. Avoid unbounded
  work and zero-delay self-rescheduling in the UI loop.
- **Persist atomically.** Validate a complete document before replacing open
  state. Save to a sibling temporary file and rename it into place so a failed
  write leaves the previous notebook intact. Save committed eraser/lasso edits
  after the gesture. Do not skip saves solely because `dirty` is false: new
  documents and path/current-page metadata can still require persistence.
- **Keep optional integrations optional.** LocalSend and PDF processing must
  fail gracefully in previews; explicit exports should report errors instead
  of silently omitting content.

## Data and exports

Notebooks use the `.scribe` extension and the versioned Bitser format. The
current format stores the document template, pages, strokes, optional page
size, content origin, paper options, and PDF background references. Storage
validation is centralized in `documentformat.lua` and
`documentstorage.lua`. Thumbnail loading validates the file but materializes
only the page it will render.

PDF export rasterizes pages and preserves the visible page appearance; it is
not an editable vector PDF. SVG and Xournal++ exports have their own support
limits. The Xournal++ file and its companion background PDF must stay together
when the notebook uses PDF pages. Check the user guide for the user-facing
export details.

## Development and verification

Run commands from the repository root unless shown otherwise. The required
local tools are LuaJIT, luacheck, Python 3, and GNU gettext's `msgfmt`.

```sh
make verify                 # lint, all configured Lua suites, translations, benchmark checks
(cd lua && luajit spec/liveink.lua)  # run one focused suite
make check-package          # build and validate the installable ZIP
make ci                     # verify plus package validation
```

The suite list is explicit in the Makefile. Each suite runs in its own LuaJIT
process through `tools/test.sh`; `TEST_JOBS=1 make test` is useful when
debugging interleaved test output. A focused suite can be run from `lua/` as
shown above.

Native offscreen feature checks use a compiled KOReader runtime and temporary
user data. They exercise UI layout, raster output, and export fixtures without
touching personal notebooks:

```sh
python3 tools/test-native-features.py
python3 tools/test-native-features.py --all-languages
```

The default runtime path is the sibling
`koreader-src/koreader-emulator-x86_64-pc-linux-gnu-debug/koreader`. Pass
`--runtime PATH` to use another compiled runtime. Use `--output DIR` to keep
the generated images and exports for inspection. These checks are offscreen:
they do not measure physical stylus latency, pressure, palm rejection, waveform
latency, ghosting, refresh blocking, suspend/resume behavior, or battery use.

For native KOReader APIs, waveform routing, and hardware behavior, use a
physical e-ink reader. Record the model, firmware, KOReader build, settings,
and the exact interaction tested. Emulator success and a backend-routing test
do not establish panel behavior or energy use. Avoid deploying test fixtures
or personal device data.

## Useful tools and references

- `tools/device-smoke.lua` checks plugin startup and native UI components.
- `tools/check-ink-reconcile.lua` checks native refresh routing without
  submitting a panel ioctl.
- `tools/bench-*.lua` and `tools/benchmark.py` measure selected offscreen
  workloads; a benchmark is not a physical-device latency result.
- [Contribution workflow](CONTRIB.md) and
  [translation guide](../lua/locale/README.md) describe related project work.
- `docs/READER_ANNOTATIONS.md` is a future design plan. Reader/PDF/EPUB text
  annotation is not part of the current plugin runtime.

## Releases and repository hygiene

`main` publishes stable releases; `dev` publishes prereleases through
semantic-release. Use short English Conventional Commits and keep independent
features or fixes separate. Before promotion, synchronize both branches, run
`make ci`, and review the native and physical checks appropriate to the change.
After publishing, verify the GitHub workflow and the downloadable ZIP; keep
`dev` synchronized with the generated stable release commit.

Keep reusable instructions here and user-facing behavior in the guide. Do not
add dated session reports or duplicate changelogs: commits and release notes
retain that history. Raw logs, benchmark output, notebook samples, private
device configuration, and backups belong outside version control. The ignored
`docs/audits/results/` path remains available for local verification output.
