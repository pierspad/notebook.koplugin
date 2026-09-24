# Notebook for KOReader

[![Release](https://img.shields.io/github/v/release/pierspad/notebook.koplugin?color=blue&label=release)](https://github.com/pierspad/notebook.koplugin/releases/latest) [![CI](https://github.com/pierspad/notebook.koplugin/actions/workflows/ci.yaml/badge.svg)](https://github.com/pierspad/notebook.koplugin/actions/workflows/ci.yaml) [![KOReader](https://img.shields.io/badge/KOReader-Plugin-238636.svg)](https://github.com/koreader/koreader)

[![GitHub Sponsors](https://img.shields.io/badge/Sponsor-%E2%9D%A4-ea4aaa?logo=github&style=flat)](https://github.com/sponsors/pierspad) [![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-Donate-yellow?logo=buymeacoffee)](https://buymeacoffee.com/pierspad) [![Ko-fi](https://img.shields.io/badge/Ko--fi-Support-ff5e5b?logo=ko-fi)](https://ko-fi.com/pierspad)

A handwriting notebook plugin for KOReader, designed for the Kindle Scribe and
other stylus-capable e-ink devices. It does not patch KOReader.

| Gallery & Organization | Drawing & Tools |
| :---: | :---: |
| <img src="docs/images/gallery.png" width="300" alt="Notebooks Gallery" /> | <img src="docs/images/drawing.png" width="300" alt="Drawing and Stylus Tools" /> |
| **Paper Templates** | **PDF & XOPP Export** |
| <img src="docs/images/templates.png" width="300" alt="Paper Templates" /> | <img src="docs/images/export.png" width="300" alt="Export Formats" /> |

## Install

1. Download the latest `notebook.koplugin-<version>.zip` from
   [Releases](https://github.com/pierspad/notebook.koplugin/releases/latest).
2. Extract `notebook.koplugin` into KOReader's plugin directory:
   - Kindle: `/mnt/us/koreader/plugins/`
   - Kobo: `/.adds/koreader/plugins/`
3. Restart KOReader, then open **Tools → More tools → Notebook**.

Notebooks are stored in `koreader/notebook/`.

> [!TIP]
> You can also place Notebook directly on KOReader's bottom navigation bar using [SimpleUI](https://github.com/doctorhetfield-cmd/simpleui.koplugin) (Custom quick actions → Plugin → Notebook, icon `F405`).

## Features

- Fineliner, pressure-sensitive fountain pen and pencil, with black or white ink.
- Highlighter; whole-stroke and partial-stroke erasers.
- Palm rejection and direct stylus input.
- Lines, arrows, rectangles, squares and circles.
- Lasso selection with move, cut, copy, paste and delete.
- Editable text, multiple pages and per-page paper templates.
- PDF and Xournal++ export; optional LocalSend integration.

Hold or double-tap a tool button to open its options. After cutting or copying,
use the Paste button in the top bar.

## Development

Requires LuaJIT and `luacheck`.

```bash
make verify       # lint and tests
make ci           # verification plus package checks
make package      # build the installable zip in build/
```

For device deployment, copy `kindle.env.example` to `kindle.env`, configure the
device, then run `make deploy`. See `tools/deploy.sh --help` for options.

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

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
