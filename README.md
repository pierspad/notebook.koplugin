# Notebook for KOReader

[![Release](https://img.shields.io/github/v/release/pierspad/notebook.koplugin?color=blue&label=release)](https://github.com/pierspad/notebook.koplugin/releases/latest) [![CI](https://github.com/pierspad/notebook.koplugin/actions/workflows/ci.yaml/badge.svg)](https://github.com/pierspad/notebook.koplugin/actions/workflows/ci.yaml) [![KOReader](https://img.shields.io/badge/KOReader-Plugin-238636.svg)](https://github.com/koreader/koreader)

[![GitHub Sponsors](https://img.shields.io/badge/Sponsor-%E2%9D%A4-ea4aaa?logo=github&style=flat)](https://github.com/sponsors/pierspad) [![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-Donate-yellow?logo=buymeacoffee)](https://buymeacoffee.com/pierspad) [![Ko-fi](https://img.shields.io/badge/Ko--fi-Support-ff5e5b?logo=ko-fi)](https://ko-fi.com/pierspad)

A handwriting notebook plugin for KOReader, designed for the Kindle Scribe and
other stylus-capable e-ink devices. It does not patch KOReader.

| Gallery & Organization | Drawing & Tools |
| :---: | :---: |
| <img src="docs/images/gallery.png" width="300" alt="Notebooks Gallery" /> | <img src="docs/images/drawing.png" width="300" alt="Drawing and Stylus Tools" /> |
| **Pen Options & Color Palette** | **Paper Templates** |
| <img src="docs/images/colored_pen.png" width="300" alt="Pen Options and Color Palette" /> | <img src="docs/images/templates.png" width="300" alt="Paper Templates" /> |
| **PDF, SVG & XOPP Export** | **Quick Action (SimpleUI)** |
| <img src="docs/images/export.png" width="300" alt="Export Formats" /> | <img src="docs/images/home.png" width="300" alt="Quick Action in SimpleUI" /> |

## Install

### From the release ZIP

1. Download `notebook.koplugin-<version>.zip` from
   [Releases](https://github.com/pierspad/notebook.koplugin/releases/latest).
   Use the attached plugin ZIP, rather than GitHub's **Source code (zip)** archive.
2. Exit KOReader. Extract the ZIP and copy its `notebook.koplugin` folder into
   your device's `koreader/plugins/` directory. On Kobo, this is usually
   `.adds/koreader/plugins/`; on Kindle, `koreader/plugins/` on the exposed storage.
3. Check that `plugins/notebook.koplugin/main.lua` exists directly inside the
   plugin folder; there should be no extra nested `notebook.koplugin` directory.
4. Restart KOReader, then open **Tools → More tools → Notebook**.

### From source, without a ZIP

No compilation is needed to install the Lua plugin directly.

1. Clone the stable branch, or download and extract GitHub's source archive:

   ```bash
   git clone --branch main --depth 1 https://github.com/pierspad/notebook.koplugin.git
   cd notebook.koplugin
   ```

   If you already have a checkout from `contrib`, use its `notebook.koplugin`
   directory instead. A detached HEAD at a release tag is normal for a submodule.
2. Exit KOReader. Create a folder named `notebook.koplugin` inside the device's
   `koreader/plugins/` directory. Copy the **contents of `lua/`** into that folder,
   including `icons/` and `locale/`. The `spec/` test directory can be omitted.
   Copy `main.lua`, `_meta.lua` and all other runtime files directly into the
   plugin folder: do not copy the outer repository or nest `lua/` inside it.
3. Check for `plugins/notebook.koplugin/main.lua`, then restart KOReader and open
   **Tools → More tools → Notebook**.

For either method, when replacing an existing installation, first move the old
plugin folder outside `plugins/` as a backup, then copy the complete new folder.
Notebooks are stored separately in `koreader/notebook/`; keep that directory.
All icons and translations are included in both methods. Git is only needed for
cloning, and developer tools (`make`, LuaJIT, luacheck, gettext) are only needed
for verification or packaging, not for copying the source plugin to a device.

After installation, **Updates → Check update** offers newer stable releases.
Restart KOReader after installing an update so it loads the new code.

## Compatibility

- **Kindle Scribe** is the primary hardware target; native KOReader checks
  have also been run on the device. Stylus input, pressure and button support
  depend on KOReader's device driver and the device firmware.
- **KOReader desktop emulator (Linux)** is used for automated checks and native
  offscreen rendering/layout tests. Mouse input can exercise the interface.
- **Other devices** are not confirmed by these tests. A stylus-capable screen
  alone does not establish compatibility; please report your model, firmware
  and KOReader version when testing another device.
- LocalSend is optional and only needed for wireless sharing. SimpleUI is
  optional; Notebook is also available from KOReader's normal Tools menu.

The source repository keeps the installable plugin in `lua/`. A source checkout
or a contrib submodule is **not** the ready-to-install plugin directory: use the
release ZIP or copy the contents of `lua/` as described above. Developers can
also run `make package` to build their own installable ZIP in `build/`.

## Features

- **Versatile Pen Tools**:
  - **Fineliner** (uniform line width), pressure-sensitive **Fountain pen**, and textured **Pencil**.
  - 5 stroke widths and an 8-color palette (Black, White, Red, Blue, Orange, Green, Yellow, Purple) with instant live preview and deferred e-ink color refresh.
- **Highlighter**: Semi-transparent marker with color options and light hatched live preview so underlying text remains readable.
- **Flexible Eraser Modes**:
  - **Whole strokes**: Erase entire strokes at once on contact.
  - **Part of a stroke**: Precise segment erasing that removes only the ink directly touched by the eraser.
  - 5 eraser size choices.
- **Shapes & Straight Strokes**:
  - Draw explicit shapes: **Square**, **Rectangle**, **Circle**, and **Triangle**, with outline or solid **Filled shape** options.
  - **Hold to straighten**: Hold the pen still at the end of a stroke to automatically snap into a straight line or an arrow (configurable in settings, enabled by default).
- **2× Writing Zoom**: Available on notebooks and imported PDF pages. Tap `2×` on the toolbar for high-precision writing, drag with a finger to pan across the page, and tap `1×` to return, with automatic background cleanup at rest.
- **Lasso Selection & Clipboard**: Select strokes and text objects with a freehand boundary to move, cut, copy, paste, duplicate, or delete them.
- **Rich Text Tool**:
  - Insert editable on-page text with **Sans-serif**, **Serif**, or **Monospace** font families.
  - Typography styles: **Bold**, **Italic**, **Underline**, and **White** or **Transparent** background.
  - 10–96 pt font size selector with −/+ stepper buttons and live sample preview.
- **Hardware Stylus Integration**: Direct digitizer event processing, palm rejection, and configurable stylus barrel button (toggle highlighter or eraser).
- **Multi-page Notebooks & Paper Templates**:
  - Multi-page management with visual thumbnail gallery and reordering.
  - Built-in paper templates: Blank, Lined, Narrow lined, Grid, Dot grid, Checklist, and custom PDF page backgrounds.
- **Export & Sync**: PDF export using the page renderer, vector SVG ink, and editable Xournal++ (`.xopp`) export, with optional wireless file transfer via LocalSend.

Hold or double-tap any tool button to open its options popover. After cutting or copying, use the Paste button in the top bar.

### Custom icons

All icons used across Notebook (toolbar tools, pen styles, shapes, lasso actions, gallery buttons, etc.) are standard SVGs and can be easily replaced.

#### Icon directories

KOReader resolves icons from two locations:
1. **Plugin directory**: `koreader/plugins/notebook.koplugin/icons/` (in this source repo: `lua/icons/`).
2. **KOReader user icons directory**: `<koreader-dir>/icons/` (e.g., `/mnt/us/koreader/icons/` on Kindle, or `/.adds/koreader/icons/` on Kobo).

On startup, Notebook automatically synchronizes its bundled icons into the KOReader user `icons/` folder so that KOReader's `IconWidget` can resolve them. You can customize any icon by replacing the SVG file in `koreader/plugins/notebook.koplugin/icons/` and/or in `<koreader-dir>/icons/`.

#### SVG requirements

- **Renderer compatibility**: KOReader uses NanoSVG; use standard SVG elements (`<path>`, `<rect>`, `<circle>`, `<polygon>`) with `fill` and `stroke`. Avoid CSS styles, `<mask/>`, or `<clipPath/>`.
- **ViewBox**: Use a square `viewBox="0 0 24 24"` or `viewBox="0 0 32 32"`.
- **Coloring**: Draw icons in solid black (`#000` or `black`) on a transparent background. KOReader automatically inverts the icon to white when selected on the toolbar or menus, and when night mode is active.
- **Cache**: Restart KOReader after modifying or adding icons so its icon cache reloads them.

## Development

Requires LuaJIT, `luacheck` and gettext (`msgfmt`). For architecture, input, rendering and tests, see the [Technical Reference Manual](docs/README.md).
Reader overlays are future work described in the [Reader Annotations Plan](docs/READER_ANNOTATIONS.md); importing a PDF as notebook paper already supports 2× zoom.
For language catalogs, see [Translating Notebook](lua/locale/README.md).

```bash
make verify       # lint and tests
make ci           # verification plus package checks
make package      # build the installable zip in build/
```

For device deployment, copy `kindle.env.example` to `kindle.env`, configure the
device, then run `make deploy`. See `tools/deploy.sh --help` for options.

### Gestures and non-obvious hints
To undo, tap twice with **two fingers per tap**, in the same area, within half
a second. The gesture is disabled while drawing with fingers, selecting objects,
using the stylus or sleeping. Redo remains available from the toolbar.

### Input debug log

To capture a device-specific pen problem, create a new notebook named `_debug_` in the Notebook gallery (or create an empty file named `_debug_` inside `koreader/notebook/`).
Then open the `_debug_` notebook, reproduce the problem, and send `koreader/notebook/notebook-debug.log` with your device model and firmware version.
The log records raw and screen coordinates, selected tools, touch events, and rotation, plus the stylus button and physical tool flags; it does not contain notebook pages or handwriting content. The log rotates at about 1 MB: if `notebook-debug.log.1` exists, send that too.
Together the two files use at most about 2 MB. Delete the `_debug_` notebook (or `_debug_` marker file) and reopen Notebook to stop logging.
You can then delete both log files.

> [!TIP]
> You can also place Notebook directly on KOReader's bottom navigation bar using [SimpleUI](https://github.com/doctorhetfield-cmd/simpleui.koplugin) (Custom quick actions → Plugin → Notebook, icon `F405`).

---

## Performance and maintenance checks

Run `make verify` for correctness, lint, translations and benchmark comparison tests.
Run `make benchmark BENCH_ARGS='--extended --jit both'` for native offscreen timings.
The runner supports isolated Kindle SSH runs and CPU, wall-time and retained-heap
regression limits; see the [current maintenance audit](docs/audits/2026-10-01-maintenance-current.md)
for commands, coverage, raw results and measurement limits.
The [1.6.0 release audit](docs/audits/2026-10-01-release-1.6.0.md) adds the mixed
edit/page/zoom/save workflow and records the release verification.
The [1.6.3 eraser audit](docs/audits/2026-10-02-release-1.6.3.md) covers continuous
rubbing of dense markers, discontinuous input and shared 1×/2× batching.

## Contributing

Pull requests are welcome! For major changes, please open an issue first to discuss your ideas.

If Notebook is useful to you and you want to support its maintenance, you can support via:
- [GitHub Sponsors](https://github.com/sponsors/pierspad)
- [Buy Me a Coffee](https://buymeacoffee.com/pierspad)
- [Ko-fi](https://ko-fi.com/pierspad)

Sponsorship is optional and does not unlock features.

---

## LLM Disclosure

This project was developed with the assistance of Large Language Models, used to support code writing and documentation.

---

## Acknowledgements

Inspired by [localsend.koplugin](https://github.com/kaikozlov/localsend.koplugin), [pencil.koplugin](https://github.com/mysticknits/pencil.koplugin), and [ink-away.koplugin](https://github.com/EmirErtorer/ink-away.koplugin).

---

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
