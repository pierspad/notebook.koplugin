# Maintenance follow-up — 2026-10-05

Second local pass over the pending changes on dev (58fc92f). Remote branch was
fetched and fast-forward synchronization confirmed no incoming changes.
All existing work was retained. No commit, publication or device deployment.

## Findings fixed with regression tests

| Area | Failure reproduced | Result |
| --- | --- | --- |
| Gallery thumbnails | Changing folders before the first scheduled tick strands the new queue | Cancellation advances a generation and releases the worker flag; stale callbacks cannot affect new work |
| XOPP companions | A failed PDF copy deletes an existing export | Stage both files, preserve the old companion, restore it when final renames fail |
| PDF metadata | Exceptions during page counting/dimensions leak document/page handles | Protected reads release handles before returning or propagating errors |
| Persisted metadata | Invalid text, font sizes, page sizes and PDF metadata are accepted | Validate before replacing the current notebook, preserving existing ink/history on failure |
| XOPP dimensions | Infinite page size is exported and replaces the destination | Reject invalid dimensions while keeping the previous export |

## Responsibilities and efficiency

- gallerythumbnails.lua owns scheduling, cancellation and queue generations.
- documentformat.lua owns validation; documentstorage.lua owns persistence.
- gzipwriter.lua incrementally writes stored DEFLATE blocks and CRC32/ISIZE.
- xopp.lua emits XML/embedded images directly to the stream instead of building
  complete XML and gzip strings. The buffered gzip payload is at most 65,535 bytes;
  this is not a bound on all export memory or native renderer allocations.
- xoppfiles.lua owns staged companion copying, commit and recovery backups.
- Existing recovery backups are refused rather than overwritten. Two files cannot
  be atomically replaced together; interruption between renames may leave a
  .rollback companion requiring recovery. The backup contains the previous PDF.

## Suite maintenance

Retained distinct input, rendering, history, filesystem and integration coverage.
No identical test files or duplicate registrations justified removing a suite.
Fixed unclosed file handles and temporary filename leaks in the interchange tests.
New coverage exercises rapid folder changes, return to the original folder, close
with pending work, PDF metadata failure cleanup, malformed persistence, source
open/read/write/close errors, backup/companion/primary rename failures, existing
recovery backups and independent gzip decoding at exact/partial block boundaries.

## Verification

- make verify: 55 Lua suites; lint of all 94 runtime modules; translations; 16
  benchmark-tool tests. All passed.
- make check-package: ZIP contents and integrity passed.
- make test-native-features: 600×800 English, 800×600 Italian, 1860×2480 Italian;
  real widgets, PNG/JPEG, persistence, reopened PDF and parsed SVG/XOPP passed.
- Native comparisons against HEAD: 672 scaled-render, 29 preview/PDF and 80 marker
  geometry comparisons; overlay/suspend checks at 1×/2× passed.
- Real KOReader bitser round trips: RGB/marker, Unicode text, PDF metadata,
  navigation and undo/redo passed.
- Private-loader completeness, Python syntax and git diff --check passed.

The audit uses static checks, production-code regressions and desktop native
rendering. It does not establish firmware-specific behavior on the reported
Kindle Scribe 2; palm rejection and long sleep still need a hardware trial.
