# Reader annotations: future integration plan

Reviewed against Notebook v1.10.0 on 23 October 2026. This document describes
future work; Notebook does not currently annotate books in KOReader's Reader.
For implemented plugin behavior and tests, see the
[technical reference](README.md) and [user guide](USER_GUIDE.md).

Notebook's canvas is a full-screen document editor. Reader annotations need to
live in the book's reading surface, follow ReaderUI's paint and navigation
cycles, and be saved separately from the original book. Moving the canvas into
ReaderUI would not provide those guarantees, especially for reflowable EPUBs.

## Boundaries and reusable parts

- Build a document-scoped Reader controller that owns annotation lifecycle and
  subscribes to ReaderUI painting, page changes, close, and suspend events.
- Keep book-specific mapping behind reader adapters. A PDF adapter maps stable
  page coordinates; a future EPUB adapter resolves text anchors after layout
  changes. Neither adapter should make the notebook canvas depend on ReaderUI.
- Store reader annotations in a versioned, document-scoped sidecar with an
  explicit migration path. Keep the storage layer separate from ReaderUI and
  from rendering so readers and exporters can share the same data model.
- Define stylus ownership through a small input-ownership service. The Reader
  controller registers drawing input only while its tool is active, yields it
  on suspend or close, and cannot leave a stale callback installed over another
  KOReader tool.
- Reuse stroke geometry, colors, erasing, smoothing, and the low-latency active
  stroke renderer where their coordinate contracts fit. Keep ReaderUI paint
  rendering responsible for committed ink; do not copy Notebook's full-screen
  canvas into the reader.
- Keep native KOReader text highlighting as its own annotation type and
  interaction. A native text highlight selects text and retains its text
  semantics; freehand ink stores drawn geometry. An explicit text-highlighter
  tool may interpret a pen gesture as a native highlight, but must not silently
  convert saved ink or duplicate a highlight in the ink sidecar.
- Preserve `pen_style`, `filled`, and text background/style fields when
  adapting or migrating notebook strokes. Missing brush metadata should retain
  the legacy appearance. Preserve `paper_options`, page geometry, and content
  origin when importing notebook pages; these are document properties, not
  anchors into book text.
- Use `penink.lua` for bounded scanline rendering and `viewcanvas.lua` for
  coordinate mapping only where the Reader adapter can supply the same
  documented geometry. Keep page geometry independent of viewport origin so
  full paints and partial dirty-region repairs agree on grain, fill, and stroke
  width.
- A notebook text preview snapshot is valid only while its page is stable. A
  Reader controller must invalidate it on navigation or reflow and release
  native text caches on close. Current canvas responsiveness work does not
  implement Reader annotations.

## First useful release

The MVP should support freehand ink on one visible page of a fixed-layout PDF.
Use stable PDF page coordinates and a versioned sidecar. It does not support
EPUB, text reflow, spreading an annotation across pages, or changing the source
PDF. Continuous scrolling, multiple visible pages and PDF reflow are outside
this first release; drawing must be visibly unavailable in unsupported modes.
It should coexist with ordinary Reader navigation while drawing is off.

Register a paintable overlay with `ReaderView:registerViewModule()`. Use the
reader's `screenToPageTransform()` and `pageToScreenTransform()` behind the PDF
adapter, verifying their supported rotation and crop modes. Transform brush
width as well as points, and clip ink to the page instead of painting over the
footer or controls. Resolve sidecar paths through KOReader's document settings
mechanism so user-configured metadata locations are respected. Keep source
PDFs unchanged; an optional annotated export is a separate later operation.

Complete an in-progress stroke before changing pages or closing. On suspend,
pause input and direct framebuffer writers before the cover is shown; persist
committed strokes and retain unfinished interaction state until the cover is
dismissed. Timers must honor screensaver and lock state and must not paint a
saved page snapshot over the cover. Render committed ink through ReaderUI's
paint cycle and reserve the fast framebuffer path for the active stroke.

## Reflow and shape limits

PDF pages have stable coordinates, but EPUB pagination changes with font,
margin, orientation, and screen size. A page number and raw screen coordinates
cannot keep an annotation beside the same text. EPUB ink needs a text range
anchor, such as an XPointer, plus a local offset or an explicit page-image
snapshot; after reflow, the adapter must resolve the anchor again.

A word or range anchor cannot by itself warp a freehand shape that crosses
multiple lines into the new layout. The design must choose and test a policy:
store line-level anchored fragments, keep a page-image snapshot with its
original layout, or leave that shape unresolved. It must not stretch one
multi-line shape between newly positioned words or silently draw it over
unrelated text. If an anchor cannot be resolved, retain the annotation in a
recoverable list so the reader can inspect, reposition, or remove it.

## Verification and phases

1. **Contracts and fixtures.** Keep the notebook format and Pencil files
   untouched. Specify controller, adapter, storage, and input-ownership
   boundaries. Add unit fixtures for coordinate mapping, versioned sidecar
   round-trips, page changes, close, suspend, and input release.
2. **PDF MVP.** Implement the fixed-layout, single-visible-page path. Test page
   rotation, zoom, clipping, partial repaint, page navigation during a stroke,
   close, suspend/cover behavior, and reopening the same PDF. Verify on device
   that normal Reader navigation works while drawing is off.
3. **Native text highlights.** Integrate KOReader text selection and highlight
   persistence as a distinct type. Test selection, anchor serialization,
   reflow, removal, and rendering independently of freehand ink.
4. **EPUB ink and recovery.** Choose a supported multi-line shape policy and
   implement text-anchor resolution. Test font, margin, orientation, and screen
   changes, failed or ambiguous anchor resolution, and the recovery list. Do
   not claim general reflow support until these cases are verified.
5. **Pencil import.** Add a read-only importer for Pencil sidecars and fixture
   tests. Only after on-device validation, offer an explicit one-way import with
   a backup of the source. Never auto-delete Pencil data.

The current Pencil rolling mode derives pages from XPointers and includes
rotation handling, but its strokes still carry page or screen geometry. That
data needs migration and validation before it can be used as reliable EPUB
anchors.
