# Translating Notebook

All translatable interface text lives in `notebook.pot`. English is the source
language and needs no `.po` file: without a catalogue, the plugin shows the
exact English `msgid` text.

To add a language:

1. Copy `notebook.pot` to `<language>.po`, for example `fr.po` or `pt_BR.po`.
2. Set the `Language:` header and replace every empty `msgstr` with its
   translation. Keep `%1`, `%2`, punctuation, newlines, and file extensions.
3. Run `make test`. The i18n suite rejects missing, empty, or obsolete entries
   in every shipped `.po` file.
4. Commit the new or updated catalogue and open a pull request.

When interface wording changes, maintainers regenerate the template with
`make translations`. Existing catalogues then fail the completeness test until
their new entries are translated, so untranslated labels cannot enter a release
unnoticed.
