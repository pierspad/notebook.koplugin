# Project scope and verification

This is the user's project: all implementation work in the parent workspace
belongs in `notebook.koplugin`.

Sibling projects are read-only references. Use them to understand KOReader APIs
or obtain ideas, but do not modify or repair them unless explicitly requested.

- Production plugin code is in `lua/`; regression suites are in `lua/spec/`.
- Run focused suites with `cd lua && luajit spec/<suite>.lua`.
- Run `make verify` for Lua lint and the complete configured test bench.
- Run `make check-package` when changing packaging or validating a deliverable.
- Reproduce bugs with tests invoking production code before applying fixes.
- Prefer small, compatible fixes that preserve notebooks, undo history, and
  responsiveness. Check I/O failures and avoid following directory symlinks in
  recursive storage operations.
- Preserve pre-existing changes. Do not commit, publish, or deploy unless asked.

## Synchronize before every task

- Before analyzing or changing code, fetch the remote and pull the latest
  version of the current branch from its configured upstream. Check the branch,
  upstream, working tree, and incoming commits first; do not assume the local
  checkout is current, since work also happens on other computers.
- Preserve dirty tracked and untracked files with a recoverable backup before
  stashing or integrating remote work. Prefer a fast-forward pull. If histories
  diverge, inspect and reconcile them explicitly; never reset away user changes
  or silently switch branches. Restore local work and verify the integration.
- If synchronization fails, state that limitation and do not present analysis
  of the local checkout as analysis of the latest remote version.

## Documentation, localization and review evidence

- Keep `README.md` as the user guide, `docs/README.md` as the technical reference,
  and `docs/READER_ANNOTATIONS.md` clearly labeled as a future integration plan.
  Update `docs/CONTRIB.md` when the tested stable release or submission workflow changes.
- Inspect replacement screenshots individually; keep installation tutorials
  unless their actual flow changed. Captions must match the pictured screen and
  state whether a visible prerelease version differs from the current release.
- After changing interface messages, update the POT and every shipped PO;
  preserve placeholders and technical filenames. Run `make verify`. For menu or
  translated layout changes, run
  `python3 tools/test-native-features.py --all-languages` with a compiled runtime.
- Keep concise, reproducible release verification in `docs/audits/`; place raw
  logs and temporary measurements outside the repository or in ignored
  `docs/audits/results/`. Historical evidence remains recoverable through Git.
- Never publish notebook samples, device backups or private device configuration
  as documentation or release artifacts. Desktop rendering does not establish
  physical stylus latency, palm rejection or e-ink refresh behavior.
