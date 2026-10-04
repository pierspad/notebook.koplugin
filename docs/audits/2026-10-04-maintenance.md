# Maintenance audit — 2026-10-04

Local working tree based on dev / 58fc92f, including the pending notebook actions,
images, paper options, diagnostics and input lifecycle changes. No device deployment.

## Review and changes

The inventory contains 90 runtime Lua files. All runtime modules have entries in
the private loader; lint covers the entire Lua tree. The review concentrates on
input ownership and suspension, framebuffer/cache ownership, history/persistence,
notebook transitions, image decoding/export and the test runner. Existing focused
renderer, eraser, history and storage suites cover distinct layers and are retained.
No identical Lua test files or duplicate suite registrations were found.

- Reopening the active notebook retains its document and undo history instead of
  loading a potentially older disk copy before saving the current edits.
- Switching finishes interactions and saves changes. A second switching step skips
  a clean existing file; a new blank notebook still gets its first save.
- Image metadata and encoding move into imagecodec.lua. Native decoding/cache
  ownership remains in imageobject.lua. SVG writes base64 in chunks.
- Base64 uses a 16 KiB output buffer, replacing a table/string per three input bytes.
- Image creation rejects invalid geometry. Loading requires consistent image tool,
  object type, MIME and bounds. JPEG dimensions cannot be read from a short SOF segment.
- Native image cache admission checks actual stride/height. Oversized results are
  freed; original and scaled buffers have explicit ownership on success/failure.
- Recent notebook scanning stops once eight valid entries have been found.
- Basic base64 cases are consolidated into the codec suite. New regression tests
  cover chunk boundaries/all byte values, 4 MiB streaming, malformed input, buffer
  ownership, save ordering, clean-switch writes and preservation of active history.

## Measurements

One local LuaJIT desktop sample, 1 MiB input, after warming each encoder and with GC
stopped during the measured call. The output is 1,398,104 bytes in both cases:

| Encoder | CPU time | Lua heap growth during call |
| --- | ---: | ---: |
| Previous | 13.553 ms | 7,263 KiB |
| Chunked | 2.061 ms | 2,430 KiB |

This isolates encoding; it does not measure total export time, native memory,
framebuffer latency or Kindle performance. Timing is not a test assertion.

## Validation

- make verify: 54 Lua suites, luacheck, all translation catalogues, 16 benchmark-tool tests.
- make test-native-features: real KOReader widgets at 600×800 English, 800×600 Italian
  and 1860×2480 Italian; PNG/JPEG decoding and embedded persistence; exported PDF
  reopened by MuPDF; embedded SVG and gzip/XML XOPP parsed and checked.
- Native comparison against the repository HEAD: 672 scaled-render comparisons,
  29 preview/PDF comparisons, 80 marker geometry comparisons, and overlay/suspend
  comparisons preserving unfinished ink at 1×/2×.
- Python syntax, all 39 SVG files, GitHub YAML and git diff --check.
- make check-package: installable ZIP integrity and required entries verified.

Hardware input and the reported Scribe 2 palm issue still require a device trial.
Passing mocks and desktop rendering do not establish firmware-specific input behavior.
