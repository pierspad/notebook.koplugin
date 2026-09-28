# Reader annotations: integration plan

This is a design plan, not an implemented reader feature. For the current
plugin architecture and tests, see the [Technical Reference Manual](README.md);
for installation and supported tools, see the [project README](../README.md).

Notebook's canvas is a full-screen document editor. Pencil is a reader overlay:
it participates in ReaderUI's paint cycle, observes page changes, and stores
annotations in a book sidecar. Moving one widget into the other will not provide
reliable EPUB annotations.

## What can be shared

- Pen input and ownership of KOReader's single stylus callback. Notebook now
  restores the callback it replaced on close and yields ownership on suspend; a shared lease API would make
  both reader and notebook surfaces use one input owner.
- Stroke geometry, colors, erasing, smoothing, and the fast framebuffer drawing
  path should live in reusable modules with no ReaderUI or gallery dependency.
- Preserve `pen_style`, `filled` and text background/style fields when adapting
  or migrating strokes. Missing brush metadata retains the legacy appearance.
- Reuse `penink.lua` for bounded scanline pen rendering and `viewcanvas.lua`
  coordinate mapping rather than duplicating zoom-specific tool logic.
- Keep page geometry independent of viewport origin: grain, fill and stroke
  width must agree between full paints and partial dirty-region repairs.
- The notebook's text preview snapshot is valid only while its page is stable.
  A reader controller must invalidate it on navigation/reflow and release
  native text caches on close. Current canvas responsiveness improvements do
  not themselves implement reader annotations.
- Rendering and export can consume the same stroke model, with a versioned
  document format and a migration path from Pencil's `pencil_strokes.lua`.

## Reader surface

The reader needs its own small controller, loaded only for a document. It must
leave KOReader's navigation available while drawing is off, and register pen
input only while drawing is on. Define and test completion of an in-progress stroke before page changes and
close. On suspend, pause input and every direct framebuffer writer before the
cover is shown; persist committed strokes and retain unfinished interaction
state until the cover is dismissed, as Notebook currently does. Timers must
respect screensaver/lock flags and cannot restore page snapshots over the cover. Render stored ink through ReaderUI's paint cycle and use
Notebook's low-latency path only for the active stroke.

Imported PDF backgrounds already support Notebook's 2× zoom, finger pan,
eraser repair and cleanup after release, including contacts ending at the screen
edge. This edits a standalone `.scribe` notebook; it does not provide a ReaderUI
overlay or change the original PDF. Hold-to-straighten only handles lines and
arrows; geometric figures remain freehand unless the explicit shape tool is used.

PDF pages have stable page coordinates. EPUB pagination changes with font,
margin, orientation, and screen size. A page number and raw screen coordinates
are insufficient to keep annotations beside the same text. An EPUB annotation
needs a text anchor (XPointer/range) plus a local offset or an explicit
page-image snapshot. When the text reflows, resolve the anchor again. If it
cannot be resolved, show the annotation in a recoverable list rather than
silently drawing it over unrelated text. Pencil's current rolling mode derives
pages from XPointers and includes rotation handling, but its strokes still
carry page/screen geometry; that data needs migration and validation before
Notebook can promise reliable reflow.

## Safe migration order

1. Keep the existing notebook format and Pencil files untouched. Add a
   read-only importer for Pencil sidecars and fixture tests.
2. Add a document-scoped reader controller for fixed-layout PDF, backed by a
   new sidecar with explicit page coordinates and version.
3. Add EPUB text anchors, reflow tests across font/margin/rotation changes,
   and an unresolved-annotation recovery view.
4. Add native KOReader text highlighting separately from freehand ink.
5. Only after on-device validation, offer an explicit one-way import with a
   backup of the Pencil source file. Never auto-delete Pencil data.
