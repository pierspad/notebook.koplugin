# Notebook for KOReader

A handwriting notebook plugin for KOReader, designed for the Kindle Scribe and
other stylus-capable e-ink devices. It does not patch KOReader.

## Install

1. Download the latest `notebook.koplugin-<version>.zip` from
   [Releases](https://github.com/pierspad/notebook.koplugin/releases/latest).
2. Extract `notebook.koplugin` into KOReader's plugin directory:
   - Kindle: `/mnt/us/koreader/plugins/`
   - Kobo: `/.adds/koreader/plugins/`
3. Restart KOReader, then open **Tools → More tools → Notebook**.

Notebooks are stored in `koreader/notebook/`.

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

If Notebook is useful to you and you want to support its maintenance, you can [sponsor the project on GitHub](https://github.com/sponsors/pierspad). Sponsorship is optional and does not unlock features.

---

## LLM Disclosure

This project was developed with the assistance of Large Language Models, used to support code writing and documentation.

---

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
