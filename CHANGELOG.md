# Changelog

## v1.0.0

First release as a plugin of its own. Everything below was built inside a
KOReader fork as `scribe.koplugin`; this is that work, extracted, renamed and
packaged.

### Writing

- Pen, highlighter and eraser, with the eraser working either by area or by
  whole strokes.
- Hold still at the end of a stroke to snap it to a line, rectangle, circle or
  triangle.
- Lasso a part of the page to move, cut, copy, paste or delete it.
- Undo and redo, and as many pages as you like, each able to take its own
  background: blank, lined, narrow lined, grid, dot grid or checklist.
- A hand resting on the glass does not draw. The pen is tracked in its own input
  slot and touches are ignored while it is down, for a moment longer than the
  stroke itself, because a hand usually leaves the glass after the nib does.

### The gallery

- Notebooks as thumbnails rather than file names, in folders.
- Rename, duplicate, move, delete and export, on one notebook or on a selection.
- Sorting by last edited, least recently edited, or name in either direction,
  remembered between sessions.
- Export to PDF, one or many, rendered a notebook per tick so the screen keeps
  answering.
- Sidecar directories KOReader writes beside an opened PDF are hidden, and the
  one belonging to a PDF you delete goes with it.

### Sending

- With [localsend.koplugin](https://github.com/kaikozlov/localsend.koplugin)
  installed, a Send action appears and hands a notebook — or a whole selection,
  rendered to PDF on the way out — to a phone over Wi-Fi.
- Entirely optional and not a dependency: nothing is required, the running
  plugin is looked up on the UI, and if it is not there the button is never
  built.

### Not falling over

- Every way the event loop can enter this plugin is behind a pcall and a
  watchdog. A fault closes the notebook, writes `notebook-error.log` and leaves
  KOReader running.
- The watchdog turns the JIT off for the duration of a protected call, because a
  count hook is not checked inside a compiled trace — which is to say that
  without it an infinite loop in a handler is a dead device, silently.
- 190 tests across ten suites, run before every push and before every deploy.

### Upgrading from `scribe.koplugin`

KOReader takes a plugin's name from its directory, so this is a rename of the
plugin itself. Handled, and tested in `lua/spec/migration.lua`:

- An existing `koreader/scribe/` folder is adopted where it stands. Notebooks
  are never moved; only fresh installs get `koreader/notebook/`.
- Settings written under the old name are still read.
- A Simple UI tab pointing at either name still opens the notebooks.

Delete the old `scribe.koplugin` directory after installing, or you will have
both.
