# Notebook for KOReader

[![Release](https://img.shields.io/github/v/release/pierspad/notebook.koplugin)](https://github.com/pierspad/notebook.koplugin/releases/latest)
[![CI](https://github.com/pierspad/notebook.koplugin/actions/workflows/ci.yaml/badge.svg)](https://github.com/pierspad/notebook.koplugin/actions/workflows/ci.yaml)

[![GitHub Sponsors](https://img.shields.io/badge/Sponsor-%E2%9D%A4-ea4aaa?logo=github&style=flat)](https://github.com/sponsors/pierspad) [![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-Donate-yellow?logo=buymeacoffee)](https://buymeacoffee.com/pierspad) [![Ko-fi](https://img.shields.io/badge/Ko--fi-Support-ff5e5b?logo=ko-fi)](https://ko-fi.com/pierspad)

A handwriting and drawing plugin for [KOReader](https://github.com/koreader/koreader), developed on Kindle Scribe.

<img src="docs/images/drawing-2026-10-05.png" width="420" alt="Notebook page with handwriting, text, highlighting and shapes" />

## Features

- Multipage notebooks, folders, page thumbnails and six paper templates.
- Fineliner, pressure-sensitive fountain pen, pencil, highlighter and two eraser modes.
- Shapes, editable text, embedded PNG/JPEG images, lasso selection, undo and redo.
- 2× writing zoom and configurable stylus button actions.
- PDF annotation and export to PDF, SVG and Xournal++.
- Optional local network sharing through [LocalSend](https://github.com/kaikozlov/localsend.koplugin).
- English interface with 13 translations.

## Installation

1. Download `notebook.koplugin-<version>.zip` from the [latest release](https://github.com/pierspad/notebook.koplugin/releases/latest). Use the release asset, not **Source code (zip)**.
2. Close KOReader and extract `notebook.koplugin` into `koreader/plugins/`.
3. Check that `main.lua` and `_meta.lua` are directly inside `plugins/notebook.koplugin/`.
4. Restart KOReader and open **Tools → More tools → Notebook**.

To install from source, copy the **contents of `lua/`**, including `icons/` and `locale/`, into `koreader/plugins/notebook.koplugin/`. No compilation is required; `spec/` can be omitted.

To update, close KOReader, move the old plugin folder outside `plugins/` as a backup, and install the new folder. Notebooks are stored separately in `koreader/notebook/`; preserve this directory. **Updates → Check for updates** checks for stable releases. Restart KOReader after installing an update.

## Usage and compatibility

Long-press or double-tap a tool to open its options. Use the gallery to create notebooks or import PDFs. PDF annotations are saved in a separate Notebook document; the original PDF is preserved.

PDF export includes backgrounds and annotations. SVG excludes paper and PDF backgrounds. Xournal++ keeps annotations editable, but approximates some brush styles; keep `.xopp` and its companion `.xopp.bg.pdf` together for PDF-based notebooks.

Kindle Scribe is the primary development device. Stylus pressure, buttons and palm rejection depend on KOReader's device support and firmware. Emulator tests cover rendering and workflows; compatibility and physical pen performance on other devices require device testing.

See the [user guide](docs/USER_GUIDE.md) for tools, screenshots, sharing and diagnostics.

## Development

Verification requires LuaJIT, luacheck and gettext (`msgfmt`).

```sh
make verify                # lint, regression tests, translations and benchmark checks
make test-native-features  # UI and export checks with a compiled KOReader runtime
make check-package         # build and validate the installable ZIP
```

See the [technical reference](docs/README.md), [translation guide](lua/locale/README.md), [contribution workflow](docs/CONTRIB.md) and [release verification](docs/audits/README.md).

Report issues with your device, firmware, KOReader and Notebook versions, and steps to reproduce the problem. Pull requests are welcome.

## License and acknowledgements

[MIT](LICENSE). Developed with assistance from language models for code and documentation, with inspiration from [LocalSend](https://github.com/kaikozlov/localsend.koplugin), [Pencil](https://github.com/mysticknits/pencil.koplugin) and [Ink Away](https://github.com/EmirErtorer/ink-away.koplugin).

Support development through [GitHub Sponsors](https://github.com/sponsors/pierspad), [Buy Me a Coffee](https://buymeacoffee.com/pierspad) or [Ko-fi](https://ko-fi.com/pierspad).
