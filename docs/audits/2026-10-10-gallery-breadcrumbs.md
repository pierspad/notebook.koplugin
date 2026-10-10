# Gallery folder breadcrumbs

The normal folder header now shows clickable folder ancestors separated by `/`.
Its double left chevron returns directly to the notebook root; the root's single
chevron still closes the gallery. Selection mode retains its cancel control.
The path uses the width left by sorting and update controls, keeps a contiguous
suffix, and exposes omitted ancestors in an ellipsis menu. Long current names
are bounded by the remaining width and truncated by KOReader's TextWidget.

Validation:

- `cd lua && luajit spec/gallery.lua`: 75 passed, including direct root navigation,
  ancestor navigation, constrained Unicode labels and hidden ancestor callbacks.
- `make verify`: passed (lint, configured suites, catalogues and benchmark tests).
- `python3 tools/test-native-features.py --all-languages --output /tmp/notebook-breadcrumb-native`:
  passed with real KOReader widgets. Added short, long Unicode and 31-level path
  cases; each asserts the header fits the screen. Rendered PNGs inspected at
  600×800 for ordinary and truncated paths.
- `git diff --check`: passed.

Native checks cover desktop layout and navigation, not physical e-ink behavior.
No new translatable messages were introduced.
