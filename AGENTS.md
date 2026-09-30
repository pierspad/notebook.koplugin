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
