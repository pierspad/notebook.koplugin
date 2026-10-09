# Opt-in prerelease updates (2026-10-09)

The Updates menu adds Include prerelease updates, disabled unless the persisted
notebook_update_prereleases setting is exactly true. This default also applies
when the installed package is itself a prerelease. The stable channel keeps the
GitHub latest endpoint; the opt-in channel examines up to 100 published releases
and selects the highest verified version, including stable releases.

Version comparison handles numeric prerelease identifiers, stable promotion and
prevents downgrades. Drafts, inconsistent tags and unverified assets are skipped.
The existing URL, filename, size, SHA-256, archive and package-version checks
remain required. Weekly checks notify; installation still requires Install.
Disabling the channel during a check filters its response back to stable; a
stale prerelease offer cannot begin installation after opt-out.

## Verification

- make ci: all 56 Lua suites, 47 palm tests, lint (0 warnings/errors), translation
  validation, 16 Python benchmark-report tests and ZIP checks pass.
- updater regression tests cover default-off settings, explicit opt-in,
  prerelease ordering, no downgrades, stable promotion, draft/invalid assets,
  endpoint selection, opt-out during transfer and stale install offers.
- python3 tools/test-native-features.py --all-languages --runtime <compiled runtime>:
  passes all profiles/languages; real Updates menu painting added to native tests.
- English and Italian Updates screenshots inspected; unchecked prerelease option
  fits the menu. Three new messages translated in all 13 shipped catalogues.
- git diff --check passes.

The same dev prerelease includes the Scribe 2 source-slot correction documented
in 2026-10-09-scribe2-slot-filter.md. Physical Scribe 2 confirmation remains
necessary; desktop tests do not establish physical pen latency.
