# Reader annotations: integration plan

Notebook's canvas is a full-screen document editor. Pencil is a reader overlay:
it participates in ReaderUI's paint cycle, observes page changes, and stores
annotations in a book sidecar. Moving one widget into the other will not provide
reliable EPUB annotations.

## What can be shared

- Pen input and ownership of KOReader's single stylus callback. Notebook now
  restores the callback it replaced on close; a shared lease API would make
  both reader and notebook surfaces use one input owner.
- Stroke geometry, colors, erasing, smoothing, and the fast framebuffer drawing
  path should live in reusable modules with no ReaderUI or gallery dependency.
- Rendering and export can consume the same stroke model, with a versioned
  document format and a migration path from Pencil's `pencil_strokes.lua`.

## Reader surface

The reader needs its own small controller, loaded only for a document. It must
leave KOReader's navigation available while drawing is off, and register pen
input only while drawing is on. Save an in-progress stroke before page changes,
suspend, and close. Render stored ink through ReaderUI's paint cycle and use
Notebook's low-latency path only for the active stroke.

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

ZenOS does not require a Notebook-specific API: Notebook registers a standard
KOReader menu action, and ZenOS's App Launcher scans those actions. The emulator
scripts install only one UI at a time and keep separate `KO_HOME` settings.
