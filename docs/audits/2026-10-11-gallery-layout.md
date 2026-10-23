# Gallery layout verification — 2026-10-11

The sort control aligns with the right edge of the title row. Version and
Updates now occupy the bottom right, below centered page navigation. Both
page arrows call the existing bounded page-turn operation. The footer is part
of the widget tree so its controls receive events and are freed with the gallery.
Action-to-grid and inter-row spacing increased by six scaled pixels.

Verification:

- `make verify` passed (lint, regression suites, catalogues and benchmark tests).
- `python3 tools/test-native-features.py --all-languages --output /tmp/notebook-gallery-layout`
  checks native gallery bounds at 600×800 and 1860×2480, plus all shipped languages.
- Inspected English 600×800 and Italian 1860×2480 gallery screenshots.
- Gallery regression exercises next/previous arrows and header/footer placement.

Native images use disposable synthetic folders. The screenshots show local
version v1.8.0; this is an emulator layout check, not a device latency check.

Follow-up controls verification:

- Page controls now reserve a centered two-digit counter and ten scaled pixels
  on each side. Native screenshots cover page 12 of 99 without shifting arrows.
- Gallery Updates opens centered rather than anchored against the lower edge.
  Dismissing the menu requests a complete UI repaint; the launcher button's
  background remains white in the native rendering.
- The local launch script defaults to gallery mode, ignoring its seeded notebook
  for that mode. Explicit notebook and home modes remain available.
- The emulatorstartup regression covers all three modes and one-shot opening.
- `make verify` passed with the new regression. Native checks now exercise the
  actual gallery Updates button and validate menu centering and button color.

Final placement adjustment:

- Updates now opens ten scaled pixels above its button, with their right edges
  aligned and the panel clamped to the screen. Other anchored action menus keep
  their existing placement.
- Version and Updates use 15-point text, increased from 12; footer reservation
  measures the enlarged button.
- `make verify` passed. Native checks assert above-button placement, right
  alignment and the white button background in every shipped language.
- Inspected the 600×800 English native screenshot for the new placement.
