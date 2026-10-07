# Line and arrow erasing (2026-10-07)

Base: main b70fd77, with the local palm-rejection changes preserved.

The eraser previously collected every `shape_kind` object for selection instead
of erasing it. Lasso selection then offered Above text / Below text for every
shape, including recognized lines and arrows. Those actions reorder the object
against all page strokes; they are retained for closed shapes such as filled
rectangles, but omitted for lines/arrows.

Recognized lines and arrows now follow the selected whole-stroke/area eraser
mode. Area erasing resamples their sparse vector segments after a confirmed hit,
so erasing the middle of a long shaft works even with only two stored endpoints.
The remaining fragments become ordinary ink; undo restores the original shape.
Closed shapes and image behavior remain covered by existing suites.

## Verification

New production tests failed before the fix, then passed:

- line/arrow erasing in both modes at 1x/2x, including a shaft midpoint;
- no eraser selection/menu, one undo group, original object restored by undo;
- open shapes omit order actions, closed shapes retain them.

`make verify` passed (56 Lua suites, lint, translations, 16 benchmark tests).
`python3 tools/test-native-features.py --all-languages` passed.
The extended native shape-order test additionally checked actual menu icons,
erased shaft pixels and undo at 1x/2x in 600x800 and 1860x2480 framebuffers.
`make check-package` passed.

The intermittent Scribe display corruption (library titles reappearing around
ink) was not reproduced. This change does not claim to resolve that separate
report; native rendering checks cannot establish the physical device behavior.
