# Drawing refinements — 21 September 2026

## Changes

- Pressure: the user's light/heavy/mixed strokes produced 2324 physical ABS_PRESSURE samples, ranging from 1 to 3944 (hardware range 0–4095). KOReader opened the `stylus-custom` virtual device, which emitted no pressure samples during the same capture. When a stylus slot has no pressure, Notebook now queries the physical `WacomDigitizer` ABS_PRESSURE state with EVIOCGABS. This does not grab or consume input events. The read-only descriptor is closed when the canvas stops. Reported slot pressure still takes precedence; unavailable hardware retains the uniform fallback.
- Shape previews restore the previous preview rectangle from one immutable framebuffer copy, then draw the next shape and issue one fast refresh. They no longer redraw underlying vector ink and perform a separate UI refresh for every frame. The raster cache is freed at gesture completion, including canvas shutdown. Frame throttling measures from frame start rather than adding another whole interval after rendering.
- Circle fitting uses the bounding-box centre rather than the sample average, avoiding a centre biased towards the slower part of a hand-drawn loop. Minimum circumference coverage rejects partial arcs. Existing spiral, polygon and ellipse rejection remains covered.
- Arrow mode accepts open curved shafts, simplifies hand tremor and applies two corner-cutting passes. Endpoints are retained; the arrowhead follows the final tangent. Closed shapes retain their existing recognition behavior.
- Partial erasing invalidates both segments adjacent to removed points, including isolated endpoints discarded from the resulting fragments. The old dirty rectangle covered only removed sample centres and left stale pixels behind.
- Active menu rows use inverted backgrounds/icons and bold white labels. Pen type and pause-at-end behavior are visibly separate sections. Replaced the fountain nib SVG; icon installation updates changed assets instead of retaining old copies forever.

## Verification

`make ci`: lint has zero warnings/errors, all 18 suites pass, and the installation ZIP passes integrity/content checks. New regressions cover uneven circle sampling, curved arrows, the physical-pressure fallback, and eraser dirty bounds for long adjacent segments and discarded singletons.

The native `tools/device-smoke.lua` passed on the Kindle with real KOReader widgets, fonts and blitbuffers, exercising menu placement, icon rendering, persistence, PDF export, repeated physical pressure sensor open/read/close, and cached shape previews. Images were inspected. Offscreen timing for 20 previews on the test page: about 65 ms/frame including shape rendering, versus 184 ms/frame for the former vector background repaint alone. This is CPU time, not a physical panel latency measurement. The user has not yet retested the updated live fountain pen or ghosting behavior.

## Interoperability

Notebook stores `.scribe` files using KOReader Persist's binary `bitser` codec, format version 1: vector point coordinates/pressure, width, colour, tool, optional shape kind and page templates. Copying a native file preserves editability in Notebook; Xournal++ does not directly understand it. Current PDF export rasterizes pages and is not an editable stroke exchange format.

A future `.xopp` exporter/importer should preserve editable vector strokes, pressure-derived widths and templates. A separate PDF background plus editable annotation layer can reuse KOReader's reader and page coordinates. The adjacent Pencil plugin already persists reader strokes in `pencil_strokes.lua` sidecars; its format is separate from Notebook. Neither XOPP interchange nor PDF backgrounds are added by this release.
