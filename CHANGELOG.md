# Changelog

## v1.1.0-rc.1

A pre-release. Nothing new to use: this is a pass over what v1.0.0 got wrong,
found by reading the code against what KOReader actually does at runtime rather
than against the test doubles.

### Writing

- Handwriting keeps its detail. Deciding whether the nib had stopped moving --
  which is how holding still snaps a shape -- was also, by accident, deciding
  whether a sample joined the stroke at all, so its eight-pixel tolerance had
  become a sampling interval. Writing came out as a chain of eight-pixel chords,
  and anything smaller than that (an accent, a comma, the bowl of a small
  letter) came out as the single dot the stroke started with. The two are now
  separate: the snap keeps its tolerance, and the ink keeps everything down to a
  couple of pixels.
- Highlighting over dot grid paper leaves the dots alone. The blend darkens a
  pixel to the tint and never past it, but the threshold it compared against was
  being read as zero on a device -- a colour there is FFI cdata, and it was
  being asked whether it was a table or a number -- so anything darker than the
  tint and not pure black was repainted over.
- Holding still no longer replaces a triangle with a different triangle. A
  three-sided shape now snaps to the corners that were drawn, straightened,
  instead of being forced onto an equilateral one; and a four-sided shape is
  only squared off when its corners are already square, so a trapezium or a
  rhombus stays what it was.

### Selecting

- Tapping the top left of the screen no longer cuts the selection. The floating
  lasso menu registered its tap area at the origin rather than where it is
  drawn, which put a live Cut button over the tool buttons for as long as
  anything was selected.
- A lasso drawn in the empty middle of an L, an arc or a large circle no longer
  selects it: containment is tested against the stroke, not against the centre
  of the box around it.
- A lasso around a few words of a line written in one stroke now catches it.
  Strokes were tested at ten points however long they were, so a small loop over
  a long stroke fell between two of them.

### Exporting

- Writing sits on the ruled lines in exported PDFs and on gallery thumbnails.
  Strokes are stored in screen coordinates and carry the height of the toolbar
  in them; the background was being drawn from the top of the page regardless,
  so the two were out of step by that height modulo the line spacing. Notebooks
  written before this release pick up the correction the first time they are
  opened.

### Not falling over

- A fault no longer leaves the pen dead until KOReader is restarted. The canvas
  patches KOReader's own input handlers while it is up and puts them back when
  the screen closes -- but a fault shuts the plugin down without that handler
  ever running, so the patches stayed in place over a reader that no longer had
  a notebook open. Tear-down that has to happen whatever went wrong is now
  registered separately from the screen that owns it.
- A notebook is written beside itself and moved into place rather than over
  itself. Saving truncated the file and then filled it, and that runs every
  couple of seconds while someone is writing: losing power inside that window
  took the whole notebook instead of the last few strokes.

### Filing

- Moving or renaming a document takes its `.sdr` sidecar along, so an exported
  PDF does not forget your reading position and bookmarks. Deleting already did.
- Copying a file no longer reads it into memory whole, which matters when it is
  an exported PDF being handed to LocalSend.

### Under the bench

- The blitbuffer double now answers about colours the way a device does, which
  is what had been hiding the highlighter bug: a test could not tell a real
  colour from a friendlier one.
- 230 tests, up from 208. Every fix above has one that fails without it.

## v1.0.0

First release.

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
- 203 tests across ten suites, run before every push and before every deploy.

### Installing

Extract `notebook.koplugin-v1.0.0.zip` into your KOReader plugins directory and
restart. On a Kindle that is `/mnt/us/koreader/plugins/`.
