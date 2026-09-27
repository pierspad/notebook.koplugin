# Notebook Plugin for KOReader: Technical Reference Manual

A comprehensive engineering reference manual documenting the architecture, hardware constraints, input subsystems, rendering pipeline, safety mechanisms, calibration infrastructure, and interoperability contracts of `notebook.koplugin`.

---

## Table of Contents

1. [Architectural Overview & Core Invariants](#1-architectural-overview--core-invariants)
   - [Plugin Identity and Directory Constraints](#11-plugin-identity-and-directory-constraints)
   - [Zero-Patch Integration Philosophy](#12-zero-patch-integration-philosophy)
   - [Directory Structure & Module Decomposition](#13-directory-structure--module-decomposition)
   - [Canvas Module Responsibility Matrix](#14-canvas-module-responsibility-matrix)
2. [Hardware Realities & E-Ink Constraints](#2-hardware-realities--e-ink-constraints)
   - [Display Resolution, Density, and Viewport Scaling](#21-display-resolution-density-and-viewport-scaling)
   - [E-Ink Waveform Pipeline & Partial Refreshes](#22-e-ink-waveform-pipeline--partial-refreshes)
   - [Digitizer and Multitouch Collision Isolation](#23-digitizer-and-multitouch-collision-isolation)
   - [Hardware Pressure Fallback via EVIOCGABS](#24-hardware-pressure-fallback-via-eviocgabs)
   - [Stylus Buttons & Proximity Handling](#25-stylus-buttons--proximity-handling)
3. [Vector Data Model & Drawing Pipeline](#3-vector-data-model--drawing-pipeline)
   - [Vector Representation vs. Bitmap Caches](#31-vector-representation-vs-bitmap-caches)
   - [Stroke Lifecycle & Coordinate Normalization](#32-stroke-lifecycle--coordinate-normalization)
   - [Pen Modalities: Uniform, Fountain, and Pencil](#33-pen-modalities-uniform-fountain-and-pencil)
   - [Highlighter Mechanics & Idempotent Min-Darkening](#34-highlighter-mechanics--idempotent-min-darkening)
   - [Palm Rejection & Outlier Velocity Filtering](#35-palm-rejection--outlier-velocity-filtering)
4. [Geometric Recognition & Shape Tools](#4-geometric-recognition--shape-tools)
   - [Hold-to-Straighten Recognition Pipeline](#41-hold-to-straighten-recognition-pipeline)
   - [Rectangle Regularization & Circle Bounding Fitting](#42-rectangle-regularization--circle-bounding-fitting)
   - [Curved Arrow Fitting & Tangent Direction](#43-curved-arrow-fitting--tangent-direction)
   - [Explicit Shapes & Background Snapshot Caching](#44-explicit-shapes--background-snapshot-caching)
5. [Eraser Subsystem](#5-eraser-subsystem)
   - [Capsule Segment Sweeping vs. Point Distance](#51-capsule-segment-sweeping-vs-point-distance)
   - [Dirty Bounds Invalidation & Viewport Clipping](#52-dirty-bounds-invalidation--viewport-clipping)
   - [Shape Preservation & Deferred Confirmation](#53-shape-preservation--deferred-confirmation)
6. [Selection, Manipulation & Clipboard](#6-selection-manipulation--clipboard)
   - [Incremental Bounding Box & Chunk Translation](#61-incremental-bounding-box--chunk-translation)
   - [Repaint Throttling & Drag Coalescing](#62-repaint-throttling--drag-coalescing)
   - [Frame Margin Padding & Ghost Removal](#63-frame-margin-padding--ghost-removal)
7. [Fault Tolerance, Sandboxing & Event Loop Safety](#7-fault-tolerance-sandboxing--event-loop-safety)
   - [KOReader Single Event Loop Hazards](#71-koreader-single-event-loop-hazards)
   - [Safe Mode Sandboxing Architecture](#72-safe-mode-sandboxing-architecture)
   - [LuaJIT Trace Compiler & Watchdog De-optimization](#73-luajit-trace-compiler--watchdog-de-optimization)
   - [Process Isolation & Dropbear SSH Recovery](#74-process-isolation--dropbear-ssh-recovery)
8. [Tuning Architecture & Engine Parameters](#8-tuning-architecture--engine-parameters)
   - [The Tuning Dock Gate (`_tuning_`)](#81-the-tuning-dock-gate-_tuning_)
   - [Complete Parameter Specification & Hardware Rationales](#82-complete-parameter-specification--hardware-rationales)
   - [Diagnostics Dump Protocol](#83-diagnostics-dump-protocol)
9. [Persistence, Formats & Interoperability](#9-persistence-formats--interoperability)
   - [The `.scribe` Document Format (Bitser Codec)](#91-the-scribe-document-format-bitser-codec)
   - [Atomic Persistence Guarantee](#92-atomic-persistence-guarantee)
   - [PDF Export Pipeline & FFI Direct Copy](#93-pdf-export-pipeline--ffi-direct-copy)
   - [LocalSend Integration Architecture](#94-localsend-integration-architecture)
   - [Rolling Debug Log Mechanism (`_debug_`)](#95-rolling-debug-log-mechanism-_debug_)
10. [Reader Annotations Architecture (Integration Plan)](#10-reader-annotations-architecture-integration-plan)
    - [Canvas vs. Document Overlay Differences](#101-canvas-vs-document-overlay-differences)
    - [Reflowable Text Anchors (XPointers) vs. Fixed Coordinates](#102-reflowable-text-anchors-xpointers-vs-fixed-coordinates)
    - [Pencil Sidecar Migration Strategy](#103-pencil-sidecar-migration-strategy)
11. [Testing, Benchmarking & Tooling Infrastructure](#11-testing-benchmarking--tooling-infrastructure)
    - [Headless Unit Test Bench](#111-headless-unit-test-bench)
    - [Hardware-Accurate UI Stubs](#112-hardware-accurate-ui-stubs)
    - [Headless SDL Verification Tools](#113-headless-sdl-verification-tools)
    - [Kindle Native Smoke Tests & Deployment Scripts](#114-kindle-native-smoke-tests--deployment-scripts)

---

## 1. Architectural Overview & Core Invariants

### 1.1 Plugin Identity and Directory Constraints

In KOReader, plugin discovery and lifecycle management are governed by `frontend/apps/pluginloader.lua`. KOReader derives a plugin's identity strictly from its directory name on disk, forcefully overriding any `name` property declared in the plugin's `main.lua` metadata table:

```lua
-- In KOReader's pluginloader.lua:
plugin.name = dir_name
```

Consequently, the directory name `notebook.koplugin` is an immutable identifier. Any renaming of this directory results in:
1. Complete dissociation of stored user settings, as configuration namespaces are keyed under `notebook_*`.
2. Breakage of external integrations, including third-party launchers such as SimpleUI, which reference the plugin by folder identity.
3. Path misalignment for default user data directories located in `koreader/notebook/`.

Compatibility invariants across installations and migrations are codified and asserted in `lua/spec/migration.lua`.

### 1.2 Zero-Patch Philosophy

`notebook.koplugin` is designed to be purely additive. It requires no modifications, monkey-patches, or binary shims within the host KOReader installation.

KOReader exposes a top-level stylus API via `Input:registerStylusCallback` (defined in `frontend/device/input.lua`). On supported hardware (e.g., Kindle Scribe), the Linux kernel opens the digitizer input device during system startup. The plugin intercepts stylus events cooperatively, claims priority when the drawing canvas is active, and restores any previously registered callback upon deactivation or failure.

Uninstallation is entirely self-contained: deleting the `koreader/plugins/notebook.koplugin` folder leaves the host KOReader environment, configuration, and reader databases in their original, untouched state.

### 1.3 Directory Structure & Module Decomposition

```
notebook.koplugin/
├── lua/                     # Core plugin runtime (packaged and installed to device)
│   ├── spec/                # Headless unit test suites, mocks, and layout validators
│   ├── locale/              # Gettext localization catalogues (.po/.pot)
│   ├── notebooktext.lua     # On-page text editor and equal-height two-row controls
│   ├── textpreview.lua      # Immutable background for active text editing
│   ├── textcache.lua        # Bounded native text widget ownership
│   ├── penpressure.lua      # Shared stylus/finger pressure response
│   ├── polygonink.lua       # Filled and outlined transformed polygon scanlines
│   ├── penink.lua           # Tapered round pen / graphite scanline rasterizer
│   ├── viewcanvas.lua       # Shared page/screen geometry and overlay restoration
│   ├── canvas.lua           # Primary canvas widget lifecycle and tool dispatch
│   ├── canvasrender.lua     # Page/background pixels and clipped repaint
│   ├── canvasrefresh.lua    # Dirty rectangles, cadence and idle color cleanup
│   ├── notebooktoolbar.lua  # Toolbar widgets and layout
│   ├── notebooksettings.lua # Tool menus and persistent settings
│   ├── galleryexport.lua    # Export/share jobs and progress
│   ├── erasercanvas.lua     # Swept capsule eraser, undo batching, and shape preservation
│   ├── selectioncanvas.lua  # Lasso selection, bounding box translation, and clipboard
│   ├── shapecanvas.lua      # Explicit geometric shape instantiation, resize, and preview
│   ├── shapesnap.lua        # Hold-to-straighten recognition timer and dispatch
│   ├── snapcanvas.lua       # Pixel replacement after hold-to-straighten recognition
│   ├── stylusbridge.lua     # Hardware slot management, multitouch isolation, button hooks
│   ├── stylusinput.lua      # Point sampling, coordinate transformation, and jitter filters
│   ├── touchinput.lua       # Multitouch gestures, palm rejection, and pan/zoom handlers
│   ├── zoomcanvas.lua       # Zoomed stylus interaction and stroke completion
│   ├── zoomcache.lua        # Enlarged page raster and viewport copies
│   ├── zoomrefresh.lua      # Pan debounce and coalesced zoom ink refreshes
│   ├── document.lua         # Document model, page collections, and persistence dispatch
│   ├── stroke.lua           # Flat-array vector stroke model and chunk bounding indexing
│   ├── renderer.lua         # Segment dispatch and page rendering
│   ├── liveink.lua          # Binary feedback and bounded snapshot restoration
│   ├── highlightink.lua     # Chisel marker pixels and scanline union
│   ├── geometryink.lua      # Rectangle and circle raster primitives
│   ├── tuning.lua           # Centralized hardware tuning parameters and calibration
│   ├── tuningdock.lua       # Interactive in-situ parameter adjustment panel
│   ├── safe.lua             # Crash protection, error trapping, and watchdog isolation
│   └── pressure.lua         # Direct Linux input ioctl fallback for physical pressure
├── tools/                   # Hardware deployment, debugging, and benchmark scripts
│   ├── deploy.sh            # Automated rsync/SSH deployment with pre-flight checks
│   ├── restart.sh           # Remote process supervisor and error log viewer
│   ├── bench-render.lua     # Micro-benchmarks for rasterization and viewport clipping
│   ├── bench-drag.lua       # Stress test for event queues and drag repaint throttling
│   └── device-smoke.lua     # Native Kindle smoke test verifying UI layout and blitbuffers
├── docs/                    # Formal technical reference and architecture documentation
└── Makefile                 # Test runner, linting, packaging, and deployment orchestration
```

### 1.4 Canvas Module Responsibility Matrix

The canvas subsystem is decomposed into specialized mixin modules loaded into the `Canvas` prototype at initialization. This avoids delegate indirection overhead during high-frequency input dispatch:

| Module | Core Responsibility | Key Invariants & Dependencies |
| :--- | :--- | :--- |
| `canvas.lua` | Session state, active tool dispatch, stroke lifecycle | Coordinates tool state; owns `Document` reference; delegates rendering and input. |
| `stylusbridge.lua` | Temporary Wacom slot routing and Linux input hooks | Isolates Wacom pen to slot 15; tracks physical barrel/eraser buttons; restores original handlers on exit. |
| `stylusinput.lua` | Point filtering, coordinate rotation, and speed gating | Normalizes raw digitizer samples; applies screen rotation; drops physical outliers. |
| `touchinput.lua` | Multitouch gestures, palm rejection, pan, page flips | Enforces `palm_grace_ms`; claims touch events inside canvas to prevent pass-through to background widgets. |
| `zoomcanvas.lua` | 2x magnification view and coordinate transformations | Maintains enlarged `Blitbuffer` cache; transforms input coordinates; handles finger pan. |
| `canvasrender.lua` | Page pixels and clipped repaint | Background cache and authoritative rendering. |
| `canvasrefresh.lua` | Dirty rectangles and E-Ink scheduling | Fast live feedback, idle color reveal and full cleanup after transformations. |
| `erasercanvas.lua` | Continuous capsule eraser and undo grouping | Performs swept segment intersection; batches atomic undos; protects geometric shapes from immediate deletion. |
| `shapecanvas.lua` | Geometric tools (rect, circle) and resize handles | Uses immutable background snapshots for previews; manages bounding handles and aspect ratios. |
| `shapesnap.lua` | Hold-to-straighten recognition timer | Debounces pen pauses (`hold_delay_ms`); triggers `Shape.recognize` on endpoint hold. |
| `selectioncanvas.lua` | Lasso selection, translation, cut/copy/paste | Translates pre-calculated bounding boxes; throttles repaint intervals; coalesces drag undo steps. |

---

## 2. Hardware Realities & E-Ink Constraints

### 2.1 Display Resolution, Density, and Viewport Scaling

The primary reference device is the Amazon Kindle Scribe:
- **Physical Panel**: 10.2″ Carta 1200 E-Ink screen.
- **Resolution**: 1860 × 2480 pixels.
- **Pixel Density**: 300 DPI.

KOReader dynamically scales UI metrics (padding, borders, icon sizes, and font dimensions) according to display DPI. Executing tests or development runs on standard 540 × 960 desktop emulator configurations at default DPI (160 DPI) obscures fatal layout bugs:
- At 1860px width, horizontal button layouts that fit on low-density displays can expand by hundreds of pixels. Early builds overflowed the top toolbar by 268px, pushing the Close button completely offscreen.
- The gallery action bar overflowed horizontally, rendering folder creation controls unreachable.
- Modal dialogs scaled proportionally exceeded screen bounds, trapping the user behind virtual keyboards without an accessible Cancel button.

All headless UI test runners MUST emulate native metrics: `EMULATE_READER_W=1860 EMULATE_READER_H=2480 EMULATE_READER_DPI=300`.

### 2.2 E-Ink Waveform Pipeline & Partial Refreshes

E-Ink displays rely on electrophoretic micro-capsules driven by specific electrical voltage pulses (waveforms). Updating an E-Ink panel introduces unique hardware constraints:

```
[Active Stroke: High Speed / Low Latency]
  Stylus Event ──> Blit Direct to Screen Buffer ──> Screen:refreshFast() (DU/A2 1-bit)
                                                           │
                                             Throttled: 1 per ~20-24 ms
                                                           │
                                                           ▼
[Pen Lift-Off: Visual Cleanliness Pass]
  Lift Detected ──> Schedule Timer (reconcile_delay_ms) ──> Screen:refreshUI() (device-selected waveform)
```

1. **Bypassing UIManager**: KOReader's `UIManager` schedules repaints across the entire widget hierarchy on every dirty notification. Triggering `UIManager:setDirty` for individual stylus samples results in severe latency (~150–300 ms lag), making writing unusable. During an active stroke, `renderer.lua` draws directly into the screen buffer (`Screen.bb`); `canvasrefresh.lua` coalesces the refresh requests passed to KOReader's device backend.
2. **Fast Binary Refresh (`refreshFast`)**: Active ink is updated using 1-bit binary waveforms (A2/DU mode). These waveforms exhibit minimal panel latency (~20–30 ms) but cannot display intermediate gray levels and leave noticeable ghosting.
3. **Refresh Throttling**: The digitizer reports samples at upwards of 200 Hz, whereas the E-Ink controller cannot process ioctl refresh calls at that rate. Issuing a refresh per sample queues work inside the kernel framebuffer driver, causing ink to lag far behind the physical pen nib. Refreshes are strictly rate-limited to at most one every `refresh_interval_ms` (default: 20 ms).
4. **Color Reconciliation (`refreshUI`)**: After pen lift, an idle timer reveals the authoritative grayscale/color pixels. Colored previews cap the configured delay at 800 ms (minimum effective delay 600 ms); ordinary cleanup retains `reconcile_delay_ms`, default 2000 ms. Active contact postpones this pass. Shape/rotation/menu cleanup requests a single full-screen refresh at rest, rather than flashing every sample.
5. **Why Grayscale Cannot Run Live**: On Kindle Scribe hardware, invoking `refreshPartial` forces the display driver into `UPDATE_MODE_FULL` and enforces a hardware fence. Successive blit operations block until previous waveform cycles complete, freezing the event loop.
6. **Boundary Clamping**: The Linux framebuffer driver silently rejects refresh ioctls containing out-of-bounds or negative coordinates. Furthermore, dirty rectangles that intersect the top toolbar trigger visual flickering of UI buttons under fast binary waveforms. All refresh rectangles are strictly clamped against the active canvas content bounding box (`self.content`).

### 2.3 Digitizer and Multitouch Collision Isolation

The Kindle Scribe incorporates two physically distinct Linux input devices:
1. A **Wacom EMR digitizer** handling passive pen tip, eraser tail, and barrel button input.
2. A **capacitive multitouch controller** handling finger touches and palm contacts.

In stock KOReader, both drivers map into a unified slot tracking structure (`cur_slot` in `frontend/device/input.lua`). When a user writes while resting their palm on the glass, a catastrophic state contamination occurs:
- The multitouch driver emits `ABS_MT_POSITION_X` and `ABS_MT_POSITION_Y` across slots 0 through 9.
- The Wacom digitizer emits `EV_ABS` events (`ABS_X`, `ABS_Y`, `ABS_PRESSURE`) without a preceding `ABS_MT_SLOT` packet.
- In unpatched handling, Wacom coordinates were written into whichever capacitive slot had last been active. Conversely, a palm touch arriving without an explicit slot reassignment would overwrite the active pen slot with palm coordinates, causing jagged line spikes across the screen.

`stylusbridge.lua` establishes strict device isolation:
```lua
-- Reassign pen slot outside the capacitive panel range (0..9)
Input.pen_slot = 15
self.panel_slot = Input.main_finger_slot or 0

-- Hook input event processor:
if ev.code == 47 then -- ABS_MT_SLOT
    self.panel_slot = ev.value
elseif ev.code >= 48 and ev.code <= 61 then -- ABS_MT_*
    this:setupSlotData(self.panel_slot)
end
if ev.code == 0 or ev.code == 1 or ev.code == 24 then -- ABS_X, ABS_Y, ABS_PRESSURE
    this:setupSlotData(this.pen_slot)
    this:setCurrentMtSlotChecked(field, ev.value)
    return
end
```

### 2.4 Hardware Pressure Fallback via EVIOCGABS

Certain Kindle Scribe firmware versions and custom virtual stylus bridges omit `ABS_PRESSURE` packets from the input event stream, forwarding contact solely as binary touch flags.

To restore pressure sensitivity without injecting synthetic input or modifying system daemons, `lua/pressure.lua` implements direct hardware interrogation via Linux ioctl:
1. Iterates `/sys/class/input/event*` searching for `device/name == "WacomDigitizer"`.
2. Opens `/dev/input/eventX` in non-blocking, read-only mode (`O_RDONLY`).
3. Dispatches `ioctl(fd, 0x80184558, absinfo)` where `0x80184558` is `EVIOCGABS(ABS_PRESSURE)`.
4. Normalizes the hardware pressure value:
   $$\text{pressure} = \text{clamp}\left(\frac{\text{value} - \text{min}}{\text{max} - \text{min}} \times 4095, 0, 4095\right)$$
5. Closes the file descriptor cleanly when the canvas shuts down. This fallback operates in parallel with normal event delivery without consuming or grabbing exclusive device ownership.

### 2.5 Stylus Buttons & Proximity Handling

Kindle Scribe styluses support hardware buttons and physical dual-end tools:
- `BTN_STYLUS` (Linux input code 331): Barrel button.
- `BTN_TOOL_PEN` (code 320): Physical pen nib proximity.
- `BTN_TOOL_RUBBER` (code 321): Physical eraser tail proximity.
- `BTN_TOUCH` (code 330): Contact state.

**Framework Bug Mitigations**:
1. **Sticky Eraser State**: KOReader's input layer can persistently overwrite `slot.tool` when the barrel button is pressed. If the stylus leaves the screen while the button is released, the framework can leave the slot permanently marked as an eraser. `stylusbridge.lua` independently caches the physical tool state reported by `BTN_TOOL_PEN` and `BTN_TOOL_RUBBER`, restoring the pen tool immediately upon button release without waiting for proximity exit.
2. **Proximity Exit Zeroing**: When the pen lifts rapidly out of range, the input subsystem may zero the tool type *before* delivering the final release event. The touch filter is hardened to recognize pen release events on slot 15 even if the tool type has already been cleared to zero, ensuring that active strokes are not left unclosed.

---

## 3. Vector Data Model & Drawing Pipeline

### 3.1 Vector Representation vs. Bitmap Caches

In `notebook.koplugin`, the vector model is the sole authoritative representation of a document. Screen bitmaps and offscreen blitbuffers are strictly transient caches that can be discarded and reconstructed at any time.

```
Document Model (Authoritative)
  └── Pages Array
        └── Page
              ├── Template Identifier
              └── Strokes Array
                    └── Stroke
                          ├── Tool ("pen", "highlighter", "eraser")
                          ├── Color (RGBA / Gray)
                          ├── Width (Base stroke thickness)
                          ├── Shape Kind (Optional: "rectangle", "circle", etc.)
                          └── Points Array: Flat 1D Table [stride 3]
                                [ x1, y1, p1,  x2, y2, p2,  ...  xn, yn, pn ]
```

**Benefits of Stride-3 Flat Arrays**:
- Memory locality: Avoids creating table objects `{x=x, y=y, p=p}` per sample point, eliminating Lua garbage collection churn during writing.
- Serialization efficiency: Flat arrays map directly to contiguous binary streams during document persistence via `bitser`.

### 3.2 Stroke Lifecycle & Coordinate Normalization

1. **Sampling**: Stylus events arrive via `stylusinput.lua` in raw hardware digitizer coordinates.
2. **Coordinate Transformation**: Coordinates are rotated and scaled according to current screen orientation:
   $$\begin{pmatrix} x_{\text{canvas}} \\ y_{\text{canvas}} \end{pmatrix} = \mathcal{R}_{\theta} \begin{pmatrix} x_{\text{raw}} \\ y_{\text{raw}} \end{pmatrix} - \begin{pmatrix} x_{\text{origin}} \\ y_{\text{origin}} \end{pmatrix}$$
3. **Jitter Floor Filtering**: Points that fall within `jitter_floor_sq` (default: 4 px²) of the previous recorded point are discarded as sensor noise.
4. **Segment Rasterization**: `penink.lua` fills the swept envelope of pressure-interpolated discs with one span per scanline. Pencil grain visits each covered pixel once per segment. The highlighter retains its separate blending rasterizer.
5. **Chunk Bounding Trees**: Every stroke divides its points into spatial chunks with pre-calculated bounding boxes. During translation or hit testing, intersection tests query chunk bounds before scanning individual points.

### 3.3 Pen Modalities: Uniform, Fountain, and Pencil

The pen tool supports three distinct rendering dynamics:
- **Uniform Pen**: Constant stroke width regardless of pressure. Ideal for technical diagrams and standard handwriting.
- **Fountain Pen**: Pressure controls width, with additional contrast from a 45-degree nib angle relative to each segment. The maximum width remains bounded by the chosen pen size.
- **Pencil**: Pressure controls width; deterministic paper grain produces a porous stroke. Black uses a softer graphite gray (96/255); other selected colors are preserved. Grain coordinates remain stable across clipped redraws and viewport translations at the same zoom level.

`penpressure.lua` shares sensor normalization and distance-based smoothing between normal and zoomed drawing. Finger input, or a stylus with no pressure source, uses a speed-based fallback. `pen_style` is stored on the stroke and retained by recognition (including arrows), cloning, erasing fragments and scaled rendering. Older strokes without this field retain their previous rendering.

### 3.4 Highlighter Mechanics & Idempotent Min-Darkening

Standard drawing programs implement highlighters using multiplicative blending or alpha compositing. On E-Ink, this approach fails:
- Multiple passes over the same word progressively darken the ink until it turns completely black.
- Overlapping stroke segments require complex offscreen alpha masks, causing high memory usage and latency.

`notebook.koplugin` implements an **idempotent minimum-darkening algorithm**:
$$\text{Pixel}_{\text{new}} = \min(\text{Pixel}_{\text{current}}, \text{Tint}_{\text{highlighter}})$$

```
White Paper (255) ───────> Darkened to Tint (200)
Dark Text (0)     ───────> Retains Dark Text (0)  [min(0, 200) = 0]
Second Pass (200) ───────> Unchanged (200)        [min(200, 200) = 200]
```

- **Mathematical Idempotence**: $\min(\min(x, t), t) = \min(x, t)$. A user can sweep over a word repeatedly without degrading legibility.
- **Live feedback**: `liveink.lua` gives colored pens a black preview and the marker a sparse black hatch, visible through `refreshFast`. On lift, it restores the touched rectangle from a framebuffer snapshot and paints only the completed stroke in its selected color. `refreshUI` reveals that color after a pause; no full document replay or slow waveform is needed for each sample. This works at 1× and 2×. The snapshot is freed on completion or shape recognition, and neither it nor the preview is serialized. One active snapshot costs one screen buffer (about 4.4 MiB at 1860×2480 in BB8; four times that in RGB32).

### 3.5 Palm Rejection & Outlier Velocity Filtering

Palm rejection operates at two coordinated levels:

1. **Velocity and Distance Gating (`_isOutlier`)**:
   A sample is flagged as an invalid jump (stray palm contact) if:
   $$\Delta d > \text{jump\_base} + \text{max\_pen\_speed} \times \min(\Delta t, \text{max\_jump\_gap\_ms})$$
   - Default `jump_base`: 48 px.
   - Default `max_pen_speed`: 6 px/ms (corresponds to an extreme flick across the screen).
   - If consecutive outliers exceed `outlier_limit` (8 samples), the filter resets and accepts the new position to prevent wedging strokes during genuine rapid transitions.

2. **Temporal Grace Window (`palm_grace_ms`)**:
   When writing, a user's palm frequently leaves the glass fractions of a second *after* the stylus nib lifts. Unhandled, this trailing touch is interpreted by the gesture engine as a swipe, triggering accidental page turns.
   `touchinput.lua` enforces a temporal grace period:
   ```lua
   function TouchInput:_touchIsPalm()
       if self.pen_down then return true end
       if self.pen_left_at and (time.now() - self.pen_left_at) < Tuning.palm_grace_ms then
           return true
       end
       return false
   end
   ```
   All touch and swipe events occurring within `palm_grace_ms` (default: 600 ms) post-lift are intercepted and discarded.

---

## 4. Geometric Recognition & Shape Tools

### 4.1 Hold-to-Straighten Recognition Pipeline

Users can draw geometric primitives freehand and convert them into regularized shapes by pausing briefly at the end of the stroke.

```
Pen Down ──> Draw Stroke ──> Nib Pauses (< 64 px² for 350 ms)
                                        │
                                        ▼
                              shapesnap.lua Timer Fires
                                        │
                                        ▼
                           shape.lua Recognition Matcher
                                        │
        ┌───────────────────────┬───────┴───────────────────────┐
        ▼                       ▼                               ▼
  Straight Line / Arrow    Rectangle / Square             Fitted Circle
```

1. **Anchor Monitoring**: When the nib travels less than `hold_travel_sq` (64 px²) over `hold_delay_ms` (350 ms), `shapesnap.lua` triggers recognition.
2. **Stroke Replacement**: The raw freehand stroke is removed from the active canvas buffer, replaced with the regularized geometry, and refreshed with a fast update.

### 4.2 Rectangle Regularization & Circle Bounding Fitting

- **Rectangles & Squares**: Polygons with 4 detected corners are evaluated for corner perpendicularity:
  $$|\theta_i - 90^\circ| \le \text{rect\_angle_tolerance} \quad (\text{default: } 18^\circ)$$
  Matching quadrilaterals are snapped to clean, page-aligned bounding rectangles. If aspect ratio width-to-height is within 10% of unity, it snaps to a perfect square.
- **Circle Fitting**: Rather than averaging sample coordinates (which biases the center toward the slower, denser portion of a hand-drawn curve), `shape.lua` calculates the center from the geometric bounding box extremes:
  $$C_x = \frac{x_{\min} + x_{\max}}{2}, \quad C_y = \frac{y_{\min} + y_{\max}}{2}, \quad R = \frac{(x_{\max} - x_{\min}) + (y_{\max} - y_{\min})}{4}$$
  Circumference coverage tests ensure partial arcs and spirals are rejected, preserving intentional open curved lines.

### 4.3 Curved Arrow Fitting & Tangent Direction

Arrow recognition accommodates open, hand-drawn curves:
1. **Tremor Reduction**: Douglas-Peucker point simplification removes minor digitizer jitter along the stroke shaft.
2. **Corner-Cutting Smoothing**: Two passes of Chaikin corner-cutting are applied to the interior points, maintaining fixed start and end coordinates.
3. **Tangent Alignment**: The arrowhead direction is derived strictly from the tangent of the final segment:
   $$\theta = \text{atan2}(y_n - y_{n-k}, x_n - x_{n-k})$$
   The arrowhead geometry is rendered symmetrically across this vector.

### 4.4 Explicit Shapes & Background Snapshot Caching

Users can create rectangles, squares, circles and triangles, with outlines or solid fills. `filled` is stored with each stroke and survives transforms, undo, clipboard copies and scaled raster exports.

`geometryink.lua` draws axis-aligned rectangles and circles as primitives. `polygonink.lua` scan-converts rotated polygons and deformed circles from their actual vertices, including filled interiors and rounded outline joins. Recognized pencil/fountain shapes use the brush renderer to retain their style.

Shape manipulation captures one immutable background snapshot. Each preview restores only the union of the old and new bounds. Rotation/resize samples are coalesced at a 50 ms interval; release always commits the latest position and cancels the trailing callback. The snapshot is freed when the gesture ends.

### 4.5 Text editing and zoom redraws

The text editor has two joined rows of five equally sized controls. The background icon toggles white/transparent; borders are painted inside the buttons so icon changes cannot alter their geometry. The preview caret uses the text layout's character coordinates and does not insert a glyph or alter wrapping.

`textpreview.lua` captures the underlying page once per edit. Typing restores dirty pixels and draws only the changing label. `textcache.lua` retains at most 32 native text widgets within an 8-million-pixel budget (except one active oversized label), freeing evicted buffers even when undo history still holds their strokes. Closing the editor cancels the preview; confirming whitespace-only text creates no label, or removes an existing label with undo support. This applies to both white and transparent backgrounds.

Zoom retains the enlarged page cache while erasing. The document returns dirty page bounds; `zoomcache.lua` repairs only that region and copies its visible intersection to the screen. Both cache construction and partial repairs include the PDF background. Pan cleanup reuses the valid cache instead of rerasterizing the page.

Shapes can now be created and rotated directly at 2× zoom: input maps to page coordinates, while handles and the floating menu map back to screen coordinates. Choosing pen, marker, eraser or shapes preserves zoom. Lasso and text editing still switch to the normal page editor; they are not zoom editing tools yet.

Completed zoomed pen strokes are recorded immediately, but their cache rasterization is deferred until that cache is actually needed. The live screen already contains the stroke, so pen-up only flushes pending fast pixels and schedules local reconciliation. Toolbar/clock-only updates paint their own band without rerendering the canvas. Colored tools use binary live previews too; slow color reconciliation waits for an idle period.

A closed selection menu restores its screen rectangle synchronously, before a rotation snapshot is captured. Selection cleanup includes the rotation handle outside the bounding box. Shape creation, rotation, menu dismissal and held-arrow recognition request one full-screen cleanup after at least 600 ms of inactivity. A new pen contact postpones it; active dragging, erasing and panning also defer it. This refresh reuses correct framebuffer pixels, without rasterizing the entire page again. Ordinary handwriting keeps local reconciliation rather than flashing after every stroke.

Input jump rejection uses consecutive kernel `slot.timev` timestamps where available, with wall-clock fallback for other input sources. A burst delivered after a slow display update must not make a legitimate fast stroke look like palm interference.

These changes reduce CPU work and avoid redundant display requests. Physical E-Ink refresh latency, ghosting, battery impact and stylus feel still require testing on the target device. The code uses KOReader's `Screen:refreshFast`, `refreshUI` and `refreshFull`; the device backend chooses the actual waveform.

---

## 5. Eraser Subsystem

### 5.1 Capsule Segment Sweeping vs. Point Distance

Initial eraser implementations tested the Euclidean distance from recorded sample points to strokes on the page. When the user erased with a rapid hand motion, sparse digitizer sampling created large spatial gaps, leaving strokes untouched between sample points.

The eraser implements **capsule segment sweeping**:
```
Sample (x1, y1) ────── Capsule Hull ──────> Sample (x2, y2)
   ( O ======================================== O )
     \── Radius ──/                  \── Radius ──/
```
The swept path between consecutive eraser events is evaluated as a continuous geometric capsule against stroke segments on the page. This guarantees gapless erasing at any hand speed without requiring expensive synthetic point interpolation.

### 5.2 Dirty Bounds Invalidation & Viewport Clipping

When partial strokes are erased:
1. The erased segment is split into remaining sub-strokes.
2. The dirty rectangle must encompass not only the removed points, but also the bounding boxes of the adjacent modified segments and discarded singleton endpoints.
3. `renderer.lua` uses shared-memory viewports (`bb:viewport`) to clip pixel writes strictly to the dirty rectangle. Pixel writes outside the dirty bounds are mathematically impossible, preventing display artifacts outside the refreshed area.

### 5.3 Shape Preservation & Deferred Confirmation

To prevent accidental destruction of complex diagrams:
- Erasing ink across an explicit geometric shape does NOT delete the shape during the sweep.
- Touched shapes are accumulated in `erase_shapes`.
- Upon pen release, if shapes were intersected, the canvas displays a lasso selection menu around them. The user can explicitly confirm deletion via the **Delete** button or tap anywhere outside to preserve them.

---

## 6. Selection, Manipulation & Clipboard

### 6.1 Incremental Bounding Box & Chunk Translation

Moving selected objects via the lasso tool involves significant coordinate arithmetic:
- **Index Preservation**: Translating strokes does not alter point membership within spatial chunks. `stroke.lua` translates existing chunk bounding boxes by $(\Delta x, \Delta y)$ rather than invalidating and rebuilding the spatial index.
- **Bounding Box Reuse**: The selection bounding box is carried forward incrementally rather than recomputed across all constituent points on each drag event.

### 6.2 Repaint Throttling & Drag Coalescing

In early versions, dragging a dense selection exhibited catastrophic latency due to a timing inversion: the interval timer was recorded *before* rasterization started. If rasterization took 80 ms, the configured 60 ms interval had already expired when the next event arrived, causing a continuous backlog of repaint jobs.

**Resolution in `selectioncanvas.lua`**:
1. The throttle interval timer is recorded strictly at the **completion** of the repaint work.
2. Intermediate motion samples arriving during an active frame are accumulated into cumulative displacement registers: `self.drag_dx` and `self.drag_dy`.
3. When the release event occurs, the final accumulated translation is committed as a **single, unified entry** in the document undo history.

### 6.3 Frame Margin Padding & Ghost Removal

The selection tool renders an animated dashed bounding frame around active selections.
- The dashed frame resides *outside* the bounding box of the strokes.
- Repainting only the selection bounding box leaves stale dashed frame segments on the screen during movement.
- `selectioncanvas.lua` pads all invalidation and refresh rectangles by `frame_margin` (default: 10 px), ensuring clean erasure of dashed borders during translation.

---

## 7. Fault Tolerance, Sandboxing & Event Loop Safety

### 7.1 KOReader Single Event Loop Hazards

KOReader executes within a single-threaded Lua/LuaJIT event loop (`frontend/ui/uimanager.lua`):
```lua
repeat
    _checkTasks()
    _repaint()
until not _task_queue_dirty
-- Hardware input polling occurs strictly AFTER this loop yields!
```

Two catastrophic failure modes exist:
1. **Uncaught Lua Errors**: An unhandled `nil` indexing error in a callback, widget layout, or input handler crashes the Lua state, instantly terminating KOReader.
2. **Event Loop Starvation**: A recursive `UIManager:nextTick` chain or an unbounded loop prevents the task queue from emptying. The loop never yields to input polling. The device becomes completely unresponsive to touch, keys, or digitizer input, forcing a hard hardware reset (holding power for 20 seconds).

### 7.2 Safe Mode Sandboxing Architecture

`lua/safe.lua` isolates `notebook.koplugin` from the host environment:

1. **`Safe.widget(Class, name)`**: Wraps critical entry points (`init`, `paintTo`, `handleEvent`) in protective `pcall` boundaries. Any crash inside the plugin widget hierarchy is caught before reaching `UIManager`.
2. **`Safe.later(delay, callback)`**: The *only* permissible mechanism for scheduling deferred work in the plugin. Disallows `UIManager:nextTick`, guaranteeing that work is scheduled at least 1 ms in the future, allowing the event loop to yield and poll hardware input.
3. **Emergency State Restoration**: If an unhandled exception occurs:
   - The original host Wacom stylus callback is restored immediately.
   - All plugin windows, overlays, and timers are aggressively dismantled.
   - The full traceback is logged to `koreader/notebook/notebook-error.log`.
   - An informative KOReader error notification is displayed. KOReader itself continues running smoothly.

### 7.3 LuaJIT Trace Compiler & Watchdog De-optimization

`Safe.watched(fn, max_instructions)` implements an execution watchdog using Lua's debug hook:
```lua
debug.sethook(watchdog_hook, "", max_instructions)
```

**Critical LuaJIT Caveat**:
LuaJIT compiles hot loops into machine code traces. JIT-compiled traces **bypass Lua VM debug count hooks entirely**. An infinite loop inside a compiled trace will never trigger `debug.sethook`, resulting in a frozen device.

`safe.lua` explicitly de-optimizes execution during watchdog-protected calls:
```lua
local jit_was_on = jit.status()
if jit_was_on then jit.off() end
local ok, err = pcall(watched_fn)
if jit_was_on then jit.on() end
```
Watchdog protection is applied strictly to UI event handlers. High-frequency inner loops (rasterization, stylus blitting) run with JIT enabled to maintain hardware performance.

### 7.4 Process Isolation & Dropbear SSH Recovery

KOReader runs Dropbear SSH as a completely independent background OS process. Even if KOReader's Lua loop hangs:
- The SSH daemon continues to accept network connections on port 2222 (KOReader SSH) or port 22 (USBNetwork).
- Developers can inspect live logs and restart the UI without rebooting the Kindle:
  ```bash
  tools/restart.sh root@192.168.1.42 --log
  ```

---

## 8. Tuning Architecture & Engine Parameters

### 8.1 The Tuning Dock Gate (`_tuning_`)

The tuning system (`tuning.lua`, `tuningdock.lua`) allows in-situ calibration of pen feel and latency directly on physical e-ink hardware without requiring recompilation or device redeployment.

- **Gate Activation**: The tuning dock is activated strictly when opening a notebook titled `_tuning_`.
- **Dock Layout**: Occupies the lower 34% of the screen (`TuningDock.HEIGHT_RATIO = 0.34`), dynamically reducing `Canvas.content`. The upper 66% remains an active, live drawing surface.
- **In-Situ Verification**: The user can alter a parameter via stepper buttons and immediately test stroke responsiveness 1 cm above the control panel.
- **Steppers vs. Sliders**: Sliders were deliberately rejected. Dragging sliders on E-Ink triggers continuous partial refresh storms, altering the very panel timing under observation. Discrete stepper buttons (`−` / `+`) perform single-step, deterministic adjustments.

### 8.2 Complete Parameter Specification & Hardware Rationales

Parameters are persisted in `G_reader_settings` under the `notebook_tuning_*` prefix and survive plugin upgrades.

| Tab | Parameter | Default | Range | Step | Engineering Rationale |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Ink** | `refresh_interval_ms` | 20 | 8–120 | 4 | Minimum time between partial screen refreshes during drawing. Matches the ~20 ms A2 waveform hardware latency. Lower values queue backlog in the kernel framebuffer. |
| **Ink** | `idle_flush_ms` | 35 | 10–200 | 5 | Delay before flushing the final stroke fragment if the pen pauses mid-stroke without lifting. |
| **Ink** | `reconcile_delay_ms` | 2000 | 200–5000 | 100 | Idle delay before revealing final grayscale/color with refreshUI; full refresh is reserved for explicit cleanup. |
| **Ink** | `jitter_floor_sq` | 4 | 0–64 | 1 | Distance squared below which incoming digitizer samples are discarded as resting sensor noise. |
| **Eraser** | `eraser_radius` | 12 | 4–80 | 2 | Base spatial collision radius (in pixels) around the eraser path. |
| **Eraser** | `erase_repaint_ms` | 70 | 16–400 | 10 | Minimum interval between vector repaints while the eraser is sweeping. Prevents CPU saturation during complex page sweeps. |
| **Lasso** | `drag_repaint_ms` | 60 | 16–400 | 10 | Minimum interval between repaints while translating selected objects. Repaint is timed from the *completion* of the previous frame. |
| **Lasso** | `lasso_sample_spacing` | 12 | 2–48 | 2 | Point-to-polygon hit testing resolution (in pixels) along strokes during loop intersection. |
| **Lasso** | `frame_margin` | 10 | 0–40 | 2 | Slack margin added around selection bounding boxes to ensure dashed boundary lines are cleanly erased during motion. |
| **Shapes** | `hold_travel_sq` | 64 | 4–400 | 4 | Maximum allowable nib wander squared (in pixels) for the recognition hold timer to remain active. |
| **Shapes** | `hold_delay_ms` | 350 | 100–1500 | 50 | Duration the nib must remain stationary at the end of a stroke before triggering shape snapping. |
| **Shapes** | `rect_angle_tolerance` | 18 | 2–45 | 1 | Maximum angular deviation (in degrees) from 90° permitted when regularizing quadrilaterals into rectangles. |
| **Input** | `palm_grace_ms` | 600 | 0–2000 | 50 | Duration after pen lift during which all touch and swipe gestures are suppressed to prevent trailing palm page turns. |
| **Input** | `max_pen_speed` | 6 | 1–30 | 1 | Maximum believable nib velocity in pixels per millisecond. Samples exceeding this threshold are treated as stray palm jumps. |
| **Input** | `jump_base` | 48 | 8–300 | 8 | Permitted baseline spatial jump distance between consecutive samples regardless of timestamp delta. |
| **Input** | `max_jump_gap_ms` | 120 | 20–500 | 20 | Maximum time delta over which pen velocity is evaluated, bounding jump distance calculations across delayed events. |
| **Input** | `outlier_limit` | 8 | 1–40 | 1 | Number of consecutive rejected outliers before resetting tracking, preventing dead strokes during genuine rapid transitions. |

### 8.3 Diagnostics Dump Protocol

Tapping **Dump** inside the tuning dock formats all non-default parameters into a pasteable Lua block and writes it directly to the KOReader system log:
```lua
notebook tuning:
  drag_repaint_ms     = 45,   -- default 60
  refresh_interval_ms = 24,   -- default 20
```
This bridges on-device physical calibration directly back to source code definitions without manual transcription error.

---

## 9. Persistence, Formats & Interoperability

### 9.1 The `.scribe` Document Format (Bitser Codec)

Notebook files are stored with the `.scribe` extension in `koreader/notebook/`. The internal format uses KOReader's high-performance binary serializer `bitser` (version 1 schema):

```lua
{
    version = 1,
    current_page = 1,
    template = "grid",
    content_origin = { x = 0, y = 72 },
    page_size = { w = 1860, h = 2400 }, -- optional
    pages = {
        {
            template = nil, -- inherits document template
            background = nil, -- or {file=pdf_path, page=1, size={w=...,h=...}}
            strokes = {
                {
                    tool = "pen", width = 3, color = 0,
                    pen_style = "fountain", -- optional; nil keeps legacy appearance
                    filled = false, shape_kind = nil,
                    n = 2, pts = {100,100,0.5, 120,130,0.8},
                    -- Text strokes also store text, font_size, font_family,
                    -- text_bold, text_italic, text_underline, text_background.
                },
            },
        },
    },
}
```

### 9.2 Atomic Persistence Guarantee

Directly overwriting an active notebook file risks corruption if battery failure or process termination occurs mid-write:
1. The document is serialized into a temporary sibling file: `filename.scribe.saving`.
2. Explicit `file:write()` and `file:close()` return codes are asserted.
3. An atomic filesystem rename (`os.rename`) replaces the original file with the temporary sibling.
4. If saving fails, the canvas remains open, preserving ink in memory and presenting an explicit error dialog.

### 9.3 PDF Export Pipeline & FFI Direct Copy

Multi-page PDF export (`export.lua`) renders vector pages into native Kindle blitbuffers (`BB8` 8-bit grayscale format).
- **FFI Row Copying**: To avoid slow per-pixel Lua conversions, row data is copied directly via LuaJIT FFI `ffi.copy` incorporating stride padding alignment:
  ```lua
  for row = 0, h - 1 do
      ffi.copy(dst_ptr + row * dst_stride, src_ptr + row * src_stride, w)
  end
  ```
- **Content Origin Cropping**: Export translations automatically offset pages by `content_origin`, cropping out UI toolbar areas while preserving page aspect ratios.

### 9.4 LocalSend Integration Architecture

Notebook supports optional, zero-configuration local network sharing via [localsend.koplugin](https://github.com/kaikozlov/localsend.koplugin):
- **Loose Coupling**: `share.lua` performs NO static `require("localsend")`. A hard require would crash Notebook if LocalSend is not installed.
- **Runtime Discovery**: Probes KOReader's active plugin registry for an active LocalSend instance.
- **Staging Pipeline**: If present, long-pressing a notebook in the gallery presents **Send**: the notebook is rendered to PDF inside `koreader/cache/` and handed off to LocalSend's background daemon. If absent, the UI option remains hidden.

### 9.5 Rolling Debug Log Mechanism (`_debug_`)

To diagnose device-specific digitizer bugs without capturing personal handwriting:
- Create a notebook named `_debug_` (or an empty file `koreader/notebook/_debug_`).
- Raw input events, Wacom slot transitions, capacitive touch coordinates, tool changes, and screen rotations are logged to `koreader/notebook/notebook-debug.log`.
- **Privacy Assurance**: Vector point histories and document text are never written to the debug log.
- **Rolling Cap**: The log rotates at 1 MB to `notebook-debug.log.1`, bounding total diagnostic disk usage strictly to ~2 MB. Deleting the `_debug_` notebook disables logging immediately.

---

## 10. Reader Annotations Architecture (Integration Plan)

### 10.1 Canvas vs. Document Overlay Differences

Integrating handwriting into KOReader's book reading view requires reconciling two fundamentally opposing UI models:

| Architectural Property | Standalone Notebook Canvas | Reader Annotation Overlay (Pencil) |
| :--- | :--- | :--- |
| **Widget Hierarchy** | Top-level full-screen modal container | Child widget participating in `ReaderUI` paint cycle |
| **Lifecycle** | Dedicated open/close document session | Attached to book lifecycle; observes background page turns |
| **Coordinate Space** | Absolute, static screen/page coordinates | Dynamic, document-relative text/page coordinates |
| **Input Ownership** | Exclusive ownership of stylus callback | Cooperative leasing; must release input during page navigation |
| **Persistence Target** | Self-contained `.scribe` files | Book-specific `.sdr/pencil_strokes.lua` sidecars |

### 10.2 Reflowable Text Anchors (XPointers) vs. Fixed Coordinates

- **Fixed-Layout Documents (PDF)**: Pages maintain permanent, immutable aspect ratios and coordinate dimensions. A vector stroke mapped to page-normalized coordinates $(u, v) \in [0, 1]^2$ renders identically across any display zoom or rotation.
- **Reflowable Documents (EPUB, MOBI, FB2)**: Pagination is non-permanent. Changing font size, typeface, line margins, or orientation completely redistributes words across pages.
  - Raw coordinates or page numbers are invalid across reflows.
  - Annotations MUST anchor to DOM/text ranges using **XPointers**.
  - If a text reflow causes an anchor to become unresolvable, the annotation MUST NOT be drawn over arbitrary text; it must be preserved in an orphaned annotation recovery list.

### 10.3 Pencil Sidecar Migration Strategy

1. **Non-Destructive Coexistence**: Notebook format and existing Pencil sidecar files remain strictly decoupled.
2. **Read-Only Importer**: A read-only migration parser converts legacy `pencil_strokes.lua` data into Notebook's versioned document model with automatic backup creation. Under no circumstances are legacy Pencil sidecars deleted.
3. **Stylus Callback Leasing API**: Refactoring KOReader's input bridge to provide a cooperative leasing mechanism, allowing ReaderUI navigation and freehand drawing overlays to arbitrate input ownership cleanly.

---

## 11. Testing, Benchmarking & Tooling Infrastructure

### 11.1 Headless Unit Test Bench

The test suite in `lua/spec/` executes directly under standard `luajit` in ~1.2 seconds without requiring an emulator, display server, or X11/Wayland session:
```bash
make test
```

The test runner exercises 20 targeted suites:
- `run`: Vector geometry, undo/redo stacks, refresh bounding calculations, highlighter blending, PDF export.
- `pages`: Multi-page lifecycle, template backgrounds, persistence round-trips.
- `eraser`: Segment capsule sweeping, dirty bounds, undo batching, shape preservation.
- `palm`: Multitouch isolation, velocity outlier rejection, temporal grace windows.
- `safe`: Exception trapping, watchdog loop termination, callback restoration.
- `i18n`: Gettext translation catalog completeness against source code strings.
- `gallery`: Card grid layouts, asynchronous thumbnail queueing, multi-selection sweeps.
- `shape` & `shapesnap`: Geometric regularization, circle fitting, arrow tangent calculation, hold timers.
- `lasso` & `lassoedit`: Loop hit-testing, coordinate translation, clipboard serialization.
- `migration`: Directory renaming compatibility, legacy configuration migration.
- `tuning`, `tuningdock`, `tuninggate`: Parameter boundary clamps, gate activation, dump formatting.
- `zoom`: 2x viewport coordinate transformations, magnified blitbuffer cache invalidation.

### 11.2 Hardware-Accurate UI Stubs

Unit tests rely on `lua/spec/uistubs.lua`. These stubs precisely model the Kindle Scribe's 300 DPI screen density:
- Simulates KOReader's `Screen:scaleBySize()` calculations.
- Enforces real widget measurement constraints: widgets added to containers after measurement cycles correctly trigger layout errors, reproducing physical device failures in headless CI.

### 11.3 Headless SDL Verification Tools

To catch visual layout overflows that pass logic unit tests, headless SDL tools render real KOReader widgets into PNG files using `SDL_VIDEODRIVER=dummy`:

```bash
export SDL_VIDEODRIVER=dummy
export EMULATE_READER_W=1860 EMULATE_READER_H=2480 EMULATE_READER_DPI=300

./luajit spec/render.lua  /tmp/notebook.png   # Verifies canvas layout at native 1860px
./luajit spec/screens.lua /tmp                # Renders all dialogs; checks keyboard overlap
./luajit spec/loop.lua                        # Audits KOReader event loop turns per action
./luajit spec/exercise.lua                    # Executes full synthetic user drawing session
```

- **`screens.lua` with `LANGUAGE=it`**: Validates localization string lengths. Longer Italian or German labels frequently push buttons beyond 1860px boundaries.
- **`loop.lua`**: Asserts that opening screens yields the event loop within 1 turn, preventing touch input starvation.

### 11.4 Kindle Native Smoke Tests & Deployment Scripts

Automated deployment and hardware verification scripts reside in `tools/`:
- **`tools/deploy.sh`**:
  Performs pre-flight test verification, probes SSH availability on port 2222 and 22 with a 3-second timeout, syncs the plugin directory, and optionally restarts KOReader.
  ```bash
  make deploy TARGET=root@192.168.1.42 FLAGS=--restart
  ```
- **`tools/device-smoke.lua`**:
  Executed natively via LuaJIT on the Kindle. Constructs real KOReader widgets, exercises blitbuffers, tests physical `EVIOCGABS` pressure queries, and exports test PDFs in offscreen memory.
- **`tools/bench-render.lua` & `tools/bench-drag.lua`**:
  Measures microsecond-level CPU performance on physical hardware, evaluating viewport clipping efficiency and drag queue coalescing.

### Interaction regression checks

`make verify` includes pixel comparisons for filled transforms, scaled brush styles, clipped pencil grain, cached erasing, text deletion/undo and bounded text cache ownership. Mock widgets do not establish compatibility with KOReader's real layout.

For native widget validation, run from a disposable KOReader SDL runtime (create the output directory first):

```sh
./luajit /path/notebook.koplugin/tools/check-interaction.lua /path/notebook.koplugin/lua /tmp/notebook-qa
```

This writes toolbar/caret screenshots and checks real input, confirmation, dismissal and button dimensions. It also compares the geometric and brush fallback paths on the same large rotated rectangle. Desktop timings measure CPU rasterization only, not Kindle refresh performance.

The editable XOPP exporter still approximates brushes as ordinary vector strokes; PDF raster export uses Notebook's renderer and preserves the visual brush/fill appearance. XOPP fidelity needs separate work and is not a guarantee of this update.

For follow-up interaction checks, `tools/check-gestures.lua` runs in the same disposable SDL runtime and verifies that closing the real floating menu removes its pixels before rotation, then exercises raw stylus shape creation at zoom and a switch back to pen. `tools/bench-pen.lua` measures long strokes offscreen and optionally accepts a baseline renderer file as its second argument. Neither benchmark measures panel latency or battery consumption.

### Parallel regression checks

`make test` runs each named suite in an independent LuaJIT process, using the
available logical CPU count and unique temporary log directories. `TEST_JOBS`
can cap concurrency. Failures preserve their full output and fail the command;
all suites finish so one failure does not conceal others. Device rendering stays
on KOReader's event loop: minimizing raster work and display requests avoids the
synchronization and memory costs of competing framebuffer workers.

`tools/check-live-ink.lua` runs against real KOReader BB8 and RGB32 buffers and
compares completed colored pen, fountain, pencil and marker strokes with a full
reference render at both zoom levels. The unit suite also covers arrow snapping,
cleanup, stored brush metadata and deferred refreshes. These checks do not
measure a physical panel's input-to-display latency.

All 13 shipped catalogs are checked for missing entries and substitution fields.
The PO reader skips unsupported contexts/plurals and decodes escapes in one
pass; locale aliases such as `pt-BR` and `it_IT@euro` resolve correctly.

### Focused performance and module maintenance

The notebook screen owns lifecycle and history; toolbar construction and tool
settings now live in `notebooktoolbar.lua` and `notebooksettings.lua`. Gallery
export/share jobs live in `galleryexport.lua`. Moving methods preserves their
existing interfaces and private loader isolation; file splitting alone is not
claimed as a speed improvement.

Constant-width marker sweeps calculate each scanline's first and last covering
stamp directly. This avoids allocating a table for every row and visiting that
row repeatedly for overlapping stamps. Pressure-varying markers retain the
existing path. Regression tests compare 600 fractional/clipped/reversed sweeps
and their binary previews with independent square stamping. The native
`tools/bench-marker.lua` comparison measures CPU work only; panel latency is
not part of the benchmark.

Lasso cut/delete uses a membership set and stable compaction instead of nested
selection searches and repeated array shifts. Recorded original indices remain
in descending order for undo. Tests include large selections, duplicate/stale
members, delete-all, batches, undo and redo.

The clock borrows a small inset from the gap immediately after it, leaving the
other controls' positions and sizes unchanged. `tools/check-toolbar.lua` can
compare their real KOReader coordinates with a prior `notebook.lua` revision.

### Text options and editing layout

Tool menus separate pen type from stroke style, geometric shape from fill,
and text font family from style and background. Text presets are replaced by
a 10–96 pt selector in 2 pt steps, with a live sample rendered by `textobject.lua`.
Text menu rows are compact enough to retain the complete menu on a 600×800
portrait viewport, including the largest sample. New headings are translated
in every shipped catalog.

`textdialog.lua` owns the keyboard dialog's visual structure; `notebooktext.lua`
owns preview, cursor, style and commit/cancel behavior. Moving the caret reuses
the existing shaped text and repaints only the union of the old/new caret
rectangles. Unchanged input notifications do no painting. Underline/background
changes reuse glyph layout; changes to content, family, weight, italic, size,
width or zoom invalidate it. Cache keys retain field references rather than
concatenating a whole label on each draw.

Underlines use each shaped line's width and horizontal origin. Thin decorations
use a bounded pixel setter to avoid older blitbuffer full-stride fill shortcuts
escaping narrow viewports. Native regression checks compare partial caret
updates pixel-for-pixel with a full label redraw. Menu close and row selection
release native preview/icon buffers rather than leaving them to collection.
