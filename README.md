## Notebook for KOReader

Handwriting notebooks for KOReader, built for the Kindle Scribe's pen.

Write freehand with the stylus, hold to snap a shape straight, lasso a drawing
and move it, keep as many pages as you like, and organise notebooks in a gallery
of thumbnails. Everything is stored as vectors, so a stroke stays sharp and can
be erased or undone on its own.

Nothing in KOReader is patched. The pen arrives through KOReader's own stylus
callback API, so this plugin is purely additive: uninstalling is deleting one
directory.

### Installation

1. Download `notebook.koplugin-<version>.zip` from the
   [latest release](https://github.com/pierspad/notebook.koplugin/releases/latest).
2. Extract it into your KOReader plugins directory, so that you end up with a
   `notebook.koplugin` folder there:
   - Kindle: `/mnt/us/koreader/plugins/`
   - Kobo: `/.adds/koreader/plugins/`
3. Restart KOReader.

The notebooks live in **Menu → Tools → More tools → Notebook**, and are saved
under `koreader/notebook/`.

### What it does

| | |
| --- | --- |
| **Writing** | Pen, highlighter and eraser. The eraser rubs out an area or removes whole strokes, whichever you prefer. |
| **Shapes** | Hold still at the end of a stroke and it snaps to the line, rectangle, circle or triangle you were drawing. |
| **Lasso** | Circle part of a page to select it, then move, cut, copy, paste or delete it. |
| **Pages** | As many as you like, each with its own background: blank, lined, narrow lined, grid, dot grid or checklist. |
| **Gallery** | Thumbnails rather than file names, in folders, sorted however you like. Rename, duplicate, move and delete in bulk. |
| **Export** | Any notebook to PDF, one or many at a time. |
| **Sending** | With [localsend.koplugin](https://github.com/kaikozlov/localsend.koplugin) installed, a Send action appears in the gallery and hands notebooks to a phone over Wi-Fi. Optional: without it, nothing appears and nothing breaks. |
| **Simple UI** | If [Simple UI](https://github.com/BetterLauncher) is installed, the gallery keeps its launcher bar and marks the notebooks tab as active. Also optional. |

### The palm, and why it matters

A hand resting on the glass is the thing that makes handwriting on a tablet
either work or not. The pen is tracked in its own input slot, and while it is
down every touch is ignored; because a hand usually leaves the glass slightly
after the nib does, the block outlasts the stroke by a moment. Writing with a
finger is off by default for the same reason — on a device with a pen, a finger
on the glass is usually somebody's hand.

### Development

```bash
make ci         # lint, test, package, and check the package: what CI runs
make verify     # lint and test only
make install-hooks
```

`make ci` is deliberately the single definition of "does this pass": the CI
workflow, the release workflow and the `pre-push` hook all call that one target,
so a push cannot fail on GitHub for something the machine could have said first.
It needs `luacheck` — `make lint` refuses to run without it rather than skipping
itself and reporting success, which is how seventeen warnings once reached CI.

The bench is 200-odd tests across ten suites and runs in about a second: it
drives the plugin headless under LuaJIT with the KOReader widget layer stubbed,
at the real geometry and density of a Scribe. The stubs are deliberately
faithful on the points that have actually caused bugs — see the comments in
`lua/spec/uistubs.lua` — because a stub that is kinder than the real widget
hides exactly the mistakes worth catching.

To put a build on a device:

```bash
cp kindle.env.example kindle.env   # then edit the address
make deploy TARGET=root@192.168.1.42 FLAGS=--restart
```

`tools/deploy.sh` runs the bench first and refuses to install a plugin that is
failing its own tests. See `tools/deploy.sh --help` for mounted devices, SSH
ports, and installing LocalSend alongside.

### Upgrading from `scribe.koplugin`

This plugin used to live inside a KOReader fork as `scribe.koplugin`. KOReader
takes a plugin's name from its directory, so the rename changes the name too,
and everything keyed on that name comes with it:

- **An existing `koreader/scribe/` folder is renamed to `koreader/notebook/`**
  the first time the notebooks are opened. It is one `os.rename` of the
  directory, which within a filesystem is a single atomic operation: the folder
  is either at the new name or at the old one, never half at each. If the rename
  cannot be made at all, the old folder keeps being used where it is.
- **Settings written under the old name are moved onto the new keys** once, and
  the old ones are deleted.
- **A Simple UI tab pointing at the old plugin still works** — both names are
  recognised. A tab created from scratch will record the new one.

Delete the old `scribe.koplugin` directory after installing this one, or you
will have both.

### License

MIT.
