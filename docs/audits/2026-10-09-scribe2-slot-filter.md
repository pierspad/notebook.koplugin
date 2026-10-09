# Scribe 2 stylus source filtering (2026-10-09)

Base: origin/main 08514af, synchronized before editing.
Compared with PR #4 head bf071ba. No production code was imported wholesale.

## Correction

Retain the contributor's dedicated-slot rejection: when Input.pen_slot exists,
other slots cannot draw, extend or release a pen contact, regardless of their
tool field. Set the contact rejection latch while the existing _touchIsPalm()
protection applies. Reuse that predicate rather than duplicate proximity and
grace timing. Keep existing tool validation for paths without a pen slot,
including virtual stylus input, and preserve release with a cleared finger tool
on the actual pen slot. No grace duration or touch handler was changed.

The previously reviewed Scribe 2 logs show slot 0/tool 2 frames resolved as pen.
This filtering addresses that specific failure and preserves the behavior the
contributor reports works on their device. Logs and notebook samples are not
included here.

## Reproduction and verification

Six new tests invoke production Canvas handlers. Before correction, five fail
(42 passed / 5 failed): mislabeled panel contacts draw or terminate pen contact
at both 1x and 2x; the palm prevents a subsequent deliberate pan. After the fix,
all 47 palm tests pass. Tests cover hover, contact, grace and idle, panel release,
real pen continuation/release, undo/redo, no-slot fallback and fresh finger pan.
Running the augmented suite against PR #4 yields 45 passed / 2 failed: the old
finger rejection test and new conservative fallback test fail. Both pass here.

- `cd lua && luajit spec/palm.lua`: 47 passed, 0 failed.
- `make verify`: all 56 Lua suites pass; lint 0 warnings/errors in 94 files;
  translation validation and 16 Python benchmark-report tests pass.
- `make check-package`: installable ZIP passes package checks.
- `git diff --check`: passes.

Raw outputs remain outside the repository in /tmp/notebook-palm-before-fix.log,
/tmp/notebook-scribe2-fix-verify.log and
/tmp/notebook-pr4-new-regression-tests.log.

## Device validation still required

No physical Scribe 2 was available. Check normal and 2x writing with the palm
resting, hover and lift; pen/eraser/barrel tools; pen toolbar taps; undo/redo;
and panning after leaving proximity, lifting the palm and starting a fresh touch.
The 600ms grace is unchanged, and an already rejected palm remains rejected until
release. Desktop tests cannot establish physical latency or complete device
compatibility. The generated ZIP retains base version v1.7.2 and is a local test
build, not a published release.
