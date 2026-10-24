# Regional marker reconciliation — 24 October 2026

## Report and cause

The user reported that rapid nearby marker strokes are faster with v1.11.0-dev.2,
but parts retain the binary stipple until a manual full refresh. Prior native
pixel comparisons confirm that the committed framebuffer matches a full render;
the photograph is consistent with incomplete panel reconciliation.

KOReader's Kindle UI waveform may update only changed pixels after fast binary
updates. The sibling InkAway implementation documents the same failure and
uses a regional partial/REAGL update to drive all committed grayscale pixels.
The actual KindleScribe runtime reports UI=257, partial=4, full=2 and confirms
that its partial waveform is REAGL.

## Change

- Preserve fast binary updates while writing and the existing 800 ms color
  debounce. New strokes postpone cleanup; dirty bounds accumulate across the
  burst, including across following black strokes.
- After the quiet window, issue exactly one `Screen:refreshPartial` on the
  clipped dirty union when grayscale/color ink needs reconciliation and the
  backend advertises REAGL. Pass the native color hint when color is enabled.
- Keep ordinary black cleanup and non-REAGL backends on their existing UI path.
  Keep explicit/manual full refresh behavior unchanged.
- Reuse the committed framebuffer. Do not rasterize the page again, repaint the
  widget stack, change device waveform settings, or update the toolbar.
- Defer pending cleanup while a contact, pan or covering surface is active.
  Unschedule stale retries; discard stale cleanup after the canvas stops.

REAGL requires a full-update-mode completion fence in the Kindle driver, even
though the request is nonflashing and uses REAGL rather than explicit flashing
GC16. It can block until the region is complete, which is why it runs only at
idle and once per burst. This is a correctness/quality tradeoff, not a claim
that REAGL is cheaper than UI refresh or that battery use has been measured.

## Verification

- The production regression failed before the fix because colored ink used UI
  cleanup instead of a regional REAGL drive.
- `make verify check-package` passes: 60 Lua suites, zero lint warnings/errors,
  translations, 16 Python tests and package validation.
- Unit coverage includes dirty-union clipping, one update per burst, active
  contacts, cover deferral, closed canvases, offscreen bounds, native color hint
  and fallback for non-REAGL backends. Existing ink pixel and suspend suites pass.
- `tools/check-ink-reconcile.lua` passed on the real Kindle runtime. It uses the
  actual Screen API and backend but intercepts `mech_refresh`, proving one
  regional, nonflashing REAGL submission with no pixel rewrite or actual ioctl.
  Thus the test does not disturb the user's visible page.
- Raw logs are in ignored `docs/audits/results/2026-10-24-refresh/`.

## Physical acceptance

After installation, draw repeated short nearby marker strokes at 1x and 2x,
then pause for about a second. Check that the stipple clears without a manual
refresh, that rapid drawing remains responsive, and that cover/sleep/resume
remain correct. Only a physical observation can confirm ghost removal on this
panel. If REAGL still leaves visible ghosts, a rarer regional flashing cleanup
needs a separate measured decision; automatic full-screen flashing is not added.
