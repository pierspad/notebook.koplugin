# Translating Notebook

All translatable interface text lives in `notebook.pot`. English is the source
language and needs no `.po` file: without a catalogue, the plugin shows the
exact English `msgid` text.

To add a language:

1. Copy `notebook.pot` to `<language>.po`, for example `fr.po` or `pt_BR.po`.
2. Set the `Language:` header and replace every empty `msgstr` with its
   translation. Keep `%1`, `%2`, punctuation, newlines, and file extensions.
3. Run `make verify` (tests, lint and gettext catalog checks). The i18n suite rejects missing, empty, or obsolete entries
   in every shipped `.po` file.
4. Commit the new or updated catalogue and open a pull request.

When interface wording changes, maintainers regenerate the template with
`make translations`. Existing catalogues then fail the completeness test until
their new entries are translated, so untranslated labels cannot enter a release
unnoticed.

The current catalogs contain 205 interface messages in 13 languages: `de`,
`es`, `fr`, `hi`, `it`, `ja`, `pl`, `pt`, `pt_BR`, `ru`, `uk`, `zh_CN`, `zh_TW`.
English remains the source language. Translated controls include settings
sections, recent notebooks, paper options, diagnostics and tool menus.
The pen menu uses **Stroke style → Line / Arrow**; hold-to-straighten is an
engine behavior, not a separate current preferences label. Remove obsolete keys from the template and every catalog
when removing a message; do not leave hardcoded replacements in the UI.

See the [project README](../../README.md) for development commands and the
[Technical Reference Manual](../../docs/README.md) for runtime architecture.

With a compiled KOReader runtime, run
`python3 tools/test-native-features.py --all-languages` to check real widget
layouts in every shipped language. Completeness tests do not replace semantic
review: keep notebook terminology consistent and translate technical meanings
without changing filenames, limits or placeholders.
