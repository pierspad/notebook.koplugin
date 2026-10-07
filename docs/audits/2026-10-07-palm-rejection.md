# Palm rejection during zoom (2026-10-07)

Base: main b70fd77 (v1.7.1), synchronized from origin/main.

## Evidence and limits

The supplied Scribe 2 logs contain panel touch gestures interleaved with pen
samples at 2x zoom. In the final log, both touch-pan events occur between active
pen samples. The older log contains 31 pan events after a pen release; second
resolution timestamps cannot establish whether the grace window had expired.
Existing logs record incoming events before rejection, not acceptance or viewport
changes. They do not prove that every unwanted mark has the same cause.
Private logs and notebook contents are not included in the repository.

## Reproduction and correction

Three tests invoke the production Canvas handlers and fail before correction:

- A hovering pen allows a panel contact to move the zoom viewport.
- A rejected contact resumes panning after the pen protection expires, and can
  finish as a swipe.
- A finger origin survives pen takeover and resumes after pen lift/grace.

Reject canvas gestures while the physical pen/eraser is in proximity. Keep a
rejected contact rejected until release; invalidate an existing zoom touch origin
when the stylus takes over. A fresh deliberate finger contact still pans after
pen proximity ends. Reject the same contact from history-tap arming and clear the
latch when cancelling input. Diagnostics now include pen/palm/rejection state,
zoom and viewport origin, allowing a future capture to distinguish receipt from
movement. Finger toolbar operation remains outside the canvas gesture filter.

## Verification

- `cd lua && luajit spec/palm.lua`: 41 passed, 0 failed.
- `make verify`: lint, all 56 Lua suites, translations and 16 benchmark tests.
- `make check-package`: validates the installable package.

## Physical follow-up

On a blank test notebook, enable input logging and compare 1x and 2x writing with
the palm resting on the page, including hovering and lifting the pen. Also begin
a finger pan, bring the pen into proximity, write, lift the pen and keep the same
finger down longer than the grace interval: the viewport must stay fixed until
finger release. Move the pen out of proximity, lift the hand and begin a fresh
finger drag: zoom panning must work again. Check pen, eraser and barrel button,
and verify toolbar taps and undo/redo. Stop logging and inspect the resulting
marks and viewport state. Desktop tests do not establish physical palm rejection
or e-ink artifacts on the device.
