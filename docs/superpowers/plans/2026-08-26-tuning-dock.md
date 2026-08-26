# Tuning dock — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Un pannello di taratura in-place, aperto solo dentro un taccuino chiamato `_tuning_`, che espone come manopole le costanti oggi locali a `canvas.lua`, `lasso.lua` e `shape.lua`.

**Architettura:** Un modulo `tuning.lua` tiene i valori (default = costanti di oggi) e li persiste su `G_reader_settings` sotto `notebook_tuning_`; i moduli leggono `T.nome` invece della costante locale. Un widget `tuningdock.lua` si costruisce da solo da `Tuning.tabs`, e `notebook.lua` lo mostra come fascia in fondo — restringendo `Canvas.content` con lo stesso meccanismo già usato per la toolbar — solo quando il titolo del taccuino è `_tuning_`.

**Stack:** Lua 5.1 / LuaJIT, widget KOReader (`InputContainer`, `FrameContainer`, `VerticalGroup`), banco di prova casalingo in `lua/spec/` eseguito da `luajit`.

## Vincoli globali

- Lua 5.1 / LuaJIT: niente `goto`, niente operatori bitwise, niente `table.unpack` (è `unpack`).
- `make lint` (luacheck) deve passare: nessuna variabile globale non dichiarata, nessuna variabile inutilizzata. Un pre-commit hook lo esegue e blocca il commit.
- Ogni nuova suite di test va aggiunta a `SUITES` nel `Makefile`, altrimenti non gira mai.
- Le stringhe rivolte all'utente passano da `_()` (`local _ = require("i18n")`). **Eccezione deliberata:** i nomi dei parametri e il banner del dock restano in inglese non tradotto, perché il dock non è destinato all'utente finale.
- Ogni schermata passa da `Safe.widget(Klass, "nome")` come ultima riga del modulo.
- Il prefisso delle chiavi salvate è esattamente `notebook_tuning_`.
- Il titolo che apre il cancello è esattamente `_tuning_`.
- Messaggi di commit in italiano, come il resto della history. **Non firmare i commit come co-autore.**
- Non toccare `build/`: è una copia generata.

---

### Task 1: Il modulo `tuning.lua`

Il contenitore dei valori. Nessun altro modulo lo usa ancora: alla fine di questo task il plugin si comporta esattamente come prima, e c'è un modulo nuovo con i suoi test.

**File:**
- Crea: `lua/tuning.lua`
- Crea: `lua/spec/tuning.lua`
- Modifica: `Makefile:26` (la riga `SUITES`)

**Interfacce:**
- Consuma: niente.
- Produce:
  - `Tuning.spec` — `{ [key] = { default=n, min=n, max=n, step=n, doc="..." } }`
  - `Tuning.tabs` — array ordinato `{ { id="ink", label="Ink", keys={"refresh_interval_ms", ...} }, ... }`
  - `Tuning[key]` — il valore corrente, numero, leggibile direttamente nei percorsi caldi
  - `Tuning.set(key, value, store)` → `number` (il valore dopo il clamp)
  - `Tuning.reset(key, store)` → `number`
  - `Tuning.resetAll(store)`
  - `Tuning.load(store)`
  - `Tuning.dump()` → `string`
  - `store` è opzionale ovunque e vale `G_reader_settings` se omesso.

`eraser_mode` **non** entra qui: è già un campo del canvas con la sua persistenza, e mescolare un toggle di stringhe in una tabella di numeri costringerebbe ogni funzione a un caso speciale. Il dock lo mostrerà chiamando il canvas (Task 4).

- [ ] **Step 1: Scrivi la suite di test, che fallisce**

Crea `lua/spec/tuning.lua`:

```lua
#!/usr/bin/env luajit
--[[--
Tests for the tuning parameters.

These numbers decide how the pen feels, and the panel that edits them is not
reachable from the test bench: what is checkable here is that the values behave
like values -- that a default is inside its own range, that a bad one saved by
an earlier build cannot get in, and that what comes out of dump goes back in.

Run with:  luajit spec/tuning.lua   (from the plugin directory)
--]]--

package.path = "./?.lua;./spec/?.lua;" .. package.path

local passed, failed = 0, 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        io.write("  ok   ", name, "\n")
    else
        failed = failed + 1
        io.write("  FAIL ", name, "\n         ", tostring(err), "\n")
    end
end

local function assertEq(got, want, what)
    if got ~= want then
        error(string.format("%s: got %s, want %s", what or "value",
            tostring(got), tostring(want)), 2)
    end
end

local function assertTrue(v, what)
    if not v then error((what or "value") .. ": expected truthy, got " .. tostring(v), 2) end
end

--- A settings store holding whatever is given, recording what happens to it.
local function storeWith(values)
    local kept = {}
    for k, v in pairs(values) do kept[k] = v end
    return {
        kept = kept,
        readSetting = function(self, k) return self.kept[k] end,
        saveSetting = function(self, k, v) self.kept[k] = v end,
        delSetting = function(self, k) self.kept[k] = nil end,
    }
end

local Tuning = require("tuning")

io.write("the spec table\n")

test("every default sits inside its own range", function()
    for key, s in pairs(Tuning.spec) do
        assertTrue(s.default >= s.min, key .. " default is below min")
        assertTrue(s.default <= s.max, key .. " default is above max")
        assertTrue(s.step > 0, key .. " has a step that goes nowhere")
        assertTrue(type(s.doc) == "string" and #s.doc > 0, key .. " has no doc")
    end
end)

test("every parameter appears on exactly one tab", function()
    local seen = {}
    for _, tab in ipairs(Tuning.tabs) do
        assertTrue(#tab.keys > 0, tab.id .. " is an empty tab")
        for _, key in ipairs(tab.keys) do
            assertTrue(Tuning.spec[key], key .. " is on a tab but not in the spec")
            assertTrue(not seen[key], key .. " is on two tabs")
            seen[key] = true
        end
    end
    for key in pairs(Tuning.spec) do
        assertTrue(seen[key], key .. " is in the spec but on no tab")
    end
end)

test("the values start at their defaults", function()
    for key, s in pairs(Tuning.spec) do
        assertEq(Tuning[key], s.default, key)
    end
end)

io.write("setting a value\n")

test("a value inside the range is taken and saved", function()
    local store = storeWith{}
    local got = Tuning.set("refresh_interval_ms", 32, store)
    assertEq(got, 32, "returned")
    assertEq(Tuning.refresh_interval_ms, 32, "field")
    assertEq(store.kept["notebook_tuning_refresh_interval_ms"], 32, "stored")
    Tuning.reset("refresh_interval_ms", store)
end)

test("a value outside the range is clamped, not refused", function()
    local store = storeWith{}
    local s = Tuning.spec.refresh_interval_ms
    assertEq(Tuning.set("refresh_interval_ms", 9999, store), s.max, "above")
    assertEq(Tuning.set("refresh_interval_ms", -5, store), s.min, "below")
    -- What was clamped is what got stored, so reloading cannot reintroduce it.
    assertEq(store.kept["notebook_tuning_refresh_interval_ms"], s.min, "stored")
    Tuning.reset("refresh_interval_ms", store)
end)

test("resetting clears the stored key rather than storing the default", function()
    -- A default that changes in a later release must reach a device that had
    -- reset the parameter, and it only can if nothing is written under the key.
    local store = storeWith{}
    Tuning.set("erase_repaint_ms", 200, store)
    Tuning.reset("erase_repaint_ms", store)
    assertEq(Tuning.erase_repaint_ms, Tuning.spec.erase_repaint_ms.default, "field")
    assertEq(store.kept["notebook_tuning_erase_repaint_ms"], nil, "stored")
end)

test("resetAll puts every parameter back", function()
    local store = storeWith{}
    Tuning.set("palm_grace_ms", 0, store)
    Tuning.set("jump_base", 200, store)
    Tuning.resetAll(store)
    for key, s in pairs(Tuning.spec) do
        assertEq(Tuning[key], s.default, key)
    end
end)

io.write("loading what was stored\n")

test("stored values are read back onto the fields", function()
    local store = storeWith{ notebook_tuning_drag_repaint_ms = 30 }
    Tuning.load(store)
    assertEq(Tuning.drag_repaint_ms, 30, "drag_repaint_ms")
    Tuning.resetAll(store)
end)

test("junk left by an earlier build cannot get in", function()
    -- Every one of these has been a real shape of stale state: a key that no
    -- longer exists, a value saved as text, and a number from a range that has
    -- since been narrowed. None of them may stop a notebook from opening.
    local store = storeWith{
        notebook_tuning_a_parameter_that_was_removed = 5,
        notebook_tuning_palm_grace_ms = "600",
        notebook_tuning_max_pen_speed = 10000,
    }
    Tuning.load(store)
    assertEq(Tuning.palm_grace_ms, Tuning.spec.palm_grace_ms.default, "text value ignored")
    assertEq(Tuning.max_pen_speed, Tuning.spec.max_pen_speed.max, "out-of-range clamped")
    assertTrue(Tuning.a_parameter_that_was_removed == nil, "unknown key not adopted")
    Tuning.resetAll(store)
end)

io.write("dump\n")

test("dump lists only what was changed, and lists it as Lua", function()
    local store = storeWith{}
    Tuning.set("refresh_interval_ms", 28, store)
    Tuning.set("erase_repaint_ms", 40, store)

    local text = Tuning.dump()
    assertTrue(text:find("refresh_interval_ms", 1, true), "changed key present")
    assertTrue(text:find("erase_repaint_ms", 1, true), "second changed key present")
    assertTrue(not text:find("palm_grace_ms", 1, true), "unchanged key absent")

    -- The point of the format is that it can be read back, so read it back.
    local chunk = loadstring("return {" .. text .. "}")
    assertTrue(chunk, "dump is not valid Lua: " .. text)
    local t = chunk()
    assertEq(t.refresh_interval_ms, 28, "round-tripped")
    assertEq(t.erase_repaint_ms, 40, "round-tripped")

    Tuning.resetAll(store)
end)

test("dump with nothing changed says so instead of returning nothing", function()
    local store = storeWith{}
    Tuning.resetAll(store)
    assertTrue(#Tuning.dump() > 0, "empty dump")
end)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
```

- [ ] **Step 2: Aggiungi la suite al Makefile**

In `Makefile`, riga 26, aggiungi `tuning` in fondo alla lista:

```make
SUITES := run pages eraser palm safe i18n gallery shape lasso lassoedit migration tuning
```

- [ ] **Step 3: Esegui la suite e verifica che fallisca**

```bash
cd lua && luajit spec/tuning.lua
```

Atteso: FAIL — `module 'tuning' not found`.

- [ ] **Step 4: Scrivi `lua/tuning.lua`**

I `doc` sono i commenti che oggi stanno sopra le costanti nei moduli: riportali per intero, non riassunti. Sotto è mostrato il testo per intero — è la parte di valore di questo lavoro, perché è l'unico posto dove sarà scritto cosa fa ogni manopola.

```lua
--[[--
The numbers that decide how the pen feels.

Every one of these used to be a `local` at the top of the module that read it,
which is where a constant belongs right up until the moment you need to try a
different one. Trying a different one meant an edit, a deploy and a restart, so
in practice none of them was ever compared against an alternative on the device
-- and the device is the only place the question can be asked, because the
emulator has neither an E-Ink panel nor a digitizer.

Here they are values instead, with a range and a step, and the tuning dock
(see `tuningdock.lua`) edits them in place while you draw. The defaults are
exactly the constants they replaced, so a plugin with the dock closed behaves
the way it always did.

Kept in `G_reader_settings`, which `make deploy` does not overwrite: tune,
update the plugin, find your values still there.

@module notebook.tuning
--]]--

local Tuning = {}

local PREFIX = "notebook_tuning_"

Tuning.spec = {
    -- Ink ---------------------------------------------------------------------
    refresh_interval_ms = {
        default = 20, min = 8, max = 120, step = 4,
        doc = "Minimum gap between partial refreshes while drawing. Roughly "
            .. "matches what an A2 update costs on this panel; going lower "
            .. "queues work faster than the hardware retires it.",
    },
    idle_flush_ms = {
        default = 35, min = 10, max = 200, step = 5,
        doc = "If the pen stops moving mid-stroke, the last fragment would "
            .. "otherwise sit unrefreshed until lift-off. This is how long we "
            .. "wait before flushing it.",
    },
    reconcile_delay_ms = {
        default = 2000, min = 200, max = 5000, step = 100,
        doc = "How long after the pen leaves the page before the grayscale "
            .. "clean-up pass runs. Generous, so handwriting never triggers a "
            .. "refresh mid-sentence.",
    },
    jitter_floor_sq = {
        default = 4, min = 0, max = 64, step = 1,
        doc = "Below this distance, squared, from the last point taken, a "
            .. "sample is wobble. Measured from the last point actually taken, "
            .. "so it can only round the path, never sample it.",
    },
    live_highlight_tint = {
        default = 100, min = 0, max = 255, step = 10,
        doc = "The gray the highlighter paints with while the stroke is still "
            .. "being drawn. Darker than the tint it settles to, so a pass over "
            .. "already-highlighted text is visible under the tip.",
    },

    -- Eraser ------------------------------------------------------------------
    eraser_radius = {
        default = 12, min = 4, max = 80, step = 2,
        doc = "How close the eraser has to come to a stroke to remove it.",
    },
    erase_repaint_ms = {
        default = 70, min = 16, max = 400, step = 10,
        doc = "Minimum gap between repaints while the eraser is sweeping. "
            .. "Every application repaints its area from the vector model, "
            .. "re-rasterising every stroke that overlaps it, which is far more "
            .. "than the panel can show.",
    },

    -- Lasso -------------------------------------------------------------------
    drag_repaint_ms = {
        default = 60, min = 16, max = 400, step = 10,
        doc = "Minimum gap between repaints while a selection is dragged. The "
            .. "same problem as the eraser and worse: the repaint covers both "
            .. "the region left and the region now covered.",
    },
    lasso_sample_spacing = {
        default = 12, min = 2, max = 48, step = 2,
        doc = "How far apart, in pixels, the points of a stroke are tested "
            .. "against the loop. Fixed rather than a fraction of the stroke's "
            .. "length, so the resolution belongs to the lasso.",
    },
    frame_margin = {
        default = 10, min = 0, max = 40, step = 2,
        doc = "Slack added around the selection's box when working out what to "
            .. "repaint, so the dashed frame is never clipped.",
    },

    -- Shapes ------------------------------------------------------------------
    hold_travel_sq = {
        default = 64, min = 4, max = 400, step = 4,
        doc = "How far the nib must travel, squared, before the shape "
            .. "recogniser accepts that it has moved at all. A nib resting on "
            .. "glass still reports a pixel or two of wander.",
    },
    hold_delay_ms = {
        default = 350, min = 100, max = 1500, step = 50,
        doc = "How long the nib must stay put before the stroke snaps to a "
            .. "shape.",
    },
    rect_angle_tolerance = {
        default = 18, min = 2, max = 45, step = 1,
        doc = "How far from square, in degrees, a quadrilateral's corners may "
            .. "be and still be regularised into a rectangle.",
    },

    -- Input -------------------------------------------------------------------
    palm_grace_ms = {
        default = 600, min = 0, max = 2000, step = 50,
        doc = "How long after the pen lifts before touches are trusted again. "
            .. "The hand usually leaves the glass slightly after the nib does, "
            .. "so the block has to outlast the stroke by a moment.",
    },
    max_pen_speed = {
        default = 6, min = 1, max = 30, step = 1,
        doc = "Fastest the nib is believed to travel, in pixels per "
            .. "millisecond. 6 px/ms is a flick right across the panel.",
    },
    jump_base = {
        default = 48, min = 8, max = 300, step = 8,
        doc = "Distance any one sample may jump regardless of how little time "
            .. "passed, which covers coarse timestamps and late-delivered "
            .. "events.",
    },
    max_jump_gap_ms = {
        default = 120, min = 20, max = 500, step = 20,
        doc = "Longest gap the speed allowance is computed over. Without a cap, "
            .. "one late event would license a jump to anywhere.",
    },
    outlier_limit = {
        default = 8, min = 1, max = 40, step = 1,
        doc = "Consecutive refusals before the position is believed after all, "
            .. "so a genuine discontinuity cannot wedge the stroke permanently.",
    },
}

--[[--
The tabs, in the order they are shown, and what is on each.

An ordered array rather than a `tab` field on each entry, because `pairs` over
the spec has no order and a panel whose rows move between openings is a panel
you cannot learn.

The grouping is by the gesture that tests it: everything on a tab is tried with
the same movement of the hand, so a tab is one sitting.
--]]
Tuning.tabs = {
    { id = "ink", label = "Ink", keys = {
        "refresh_interval_ms", "idle_flush_ms", "reconcile_delay_ms",
        "jitter_floor_sq", "live_highlight_tint",
    } },
    { id = "eraser", label = "Eraser", keys = {
        "eraser_radius", "erase_repaint_ms",
    } },
    { id = "lasso", label = "Lasso", keys = {
        "drag_repaint_ms", "lasso_sample_spacing", "frame_margin",
    } },
    { id = "shapes", label = "Shapes", keys = {
        "hold_travel_sq", "hold_delay_ms", "rect_angle_tolerance",
    } },
    { id = "input", label = "Input", keys = {
        "palm_grace_ms", "max_pen_speed", "jump_base", "max_jump_gap_ms",
        "outlier_limit",
    } },
}

for key, s in pairs(Tuning.spec) do
    Tuning[key] = s.default
end

--- The store to use when the caller did not name one.
local function storeOr(store)
    return store or G_reader_settings
end

local function clamp(s, value)
    if value < s.min then return s.min end
    if value > s.max then return s.max end
    return value
end

--[[--
Sets a parameter, clamped to its range, and remembers it.

Clamped rather than refused: the caller here is a panel with a plus button on
it, and the useful answer when you hold plus at the top of the range is to stay
at the top, not to reject the tap. It is also the second line of defence for a
stored value, which is checked on the way in as well.
--]]
function Tuning.set(key, value, store)
    local s = Tuning.spec[key]
    if not s or type(value) ~= "number" then return Tuning[key] end
    local v = clamp(s, value)
    Tuning[key] = v
    storeOr(store):saveSetting(PREFIX .. key, v)
    return v
end

--[[--
Puts a parameter back to its default.

The stored key is deleted rather than written with the default in it. A default
that changes in a later release has to reach a device where the parameter was
reset, and it only can if there is nothing saved under that name.
--]]
function Tuning.reset(key, store)
    local s = Tuning.spec[key]
    if not s then return end
    Tuning[key] = s.default
    storeOr(store):delSetting(PREFIX .. key)
    return Tuning[key]
end

function Tuning.resetAll(store)
    for key in pairs(Tuning.spec) do
        Tuning.reset(key, store)
    end
end

--[[--
Reads the stored values onto the fields.

Anything that is not a number is dropped and anything outside the range is
clamped, because what is in the store was written by an older build of this
plugin and its idea of these keys is not this one's. A parameter that has since
been removed is simply not in the spec, so it is never looked at. None of that
state may stop a notebook from opening.
--]]
function Tuning.load(store)
    local s_store = storeOr(store)
    for key, s in pairs(Tuning.spec) do
        local value = s_store:readSetting(PREFIX .. key)
        if type(value) == "number" then
            Tuning[key] = clamp(s, value)
        else
            Tuning[key] = s.default
        end
    end
end

--[[--
The parameters that are not at their default, as Lua you can paste.

This is the bridge from a tuning session to the source. Without it what is left
at the end of an afternoon is fifteen numbers to copy off a screen by hand,
which is exactly where a tuning session gets lost.

Only what changed, because a list of seventeen lines where two matter is a list
nobody reads. Sorted, so two dumps of the same state are the same text.
--]]
function Tuning.dump()
    local keys = {}
    for key, s in pairs(Tuning.spec) do
        if Tuning[key] ~= s.default then table.insert(keys, key) end
    end
    if #keys == 0 then return "-- every parameter is at its default" end
    table.sort(keys)

    local width = 0
    for _, key in ipairs(keys) do
        if #key > width then width = #key end
    end

    local out = {}
    for _, key in ipairs(keys) do
        table.insert(out, string.format("%-" .. width .. "s = %s, -- default %s",
            key, tostring(Tuning[key]), tostring(Tuning.spec[key].default)))
    end
    return table.concat(out, "\n")
end

return Tuning
```

- [ ] **Step 5: Esegui la suite e verifica che passi**

```bash
cd lua && luajit spec/tuning.lua
```

Atteso: `11 passed, 0 failed`.

- [ ] **Step 6: Lint**

```bash
make lint
```

Atteso: `0 warnings / 0 errors`. Se luacheck si lamenta di `G_reader_settings` come globale non dichiarata, aggiungila alla lista `globals`/`read_globals` in `.luacheckrc` — è già come il resto del plugin vi accede.

- [ ] **Step 7: Commit**

```bash
git add lua/tuning.lua lua/spec/tuning.lua Makefile
git commit -m "tuning: i parametri come valori invece che come costanti

Un modulo che tiene i numeri che decidono la sensazione della penna, con
range, passo e la spiegazione di ognuno, persistiti sotto notebook_tuning_.
Nessuno li usa ancora: i default sono le costanti di oggi."
```

---

### Task 2: I moduli leggono da `Tuning`

Il momento delicato: le costanti spariscono e al loro posto ci sono letture di campo. Il comportamento non deve cambiare di un pixel, e c'è un test che lo dimostra numero per numero.

**File:**
- Modifica: `lua/canvas.lua:51-156` (le costanti), `lua/canvas.lua:505` (`FRAME_MARGIN`), e ogni punto d'uso
- Modifica: `lua/lasso.lua:30-40` (`SAMPLE_SPACING`)
- Modifica: `lua/shape.lua:239` (`RECT_ANGLE_TOLERANCE`)
- Modifica: `lua/spec/tuning.lua` (aggiungi il test di equivalenza)

**Interfacce:**
- Consuma: `Tuning[key]`, `Tuning.spec` dal Task 1.
- Produce: niente di nuovo. `Canvas`, `Lasso` e `Shape` mantengono la stessa API pubblica.

- [ ] **Step 1: Scrivi il test di equivalenza, che fallisce**

In `lua/spec/tuning.lua`, subito prima della riga del sommario (`io.write(string.format("\n%d passed...`), aggiungi:

```lua
io.write("equivalence with the constants that were replaced\n")

test("the defaults are the numbers the modules used to hold", function()
    -- The whole risk of moving these out of the modules is changing one of
    -- them by accident on the way, and the symptom would be the pen feeling
    -- different for a reason nobody could name. This is the guard: the values
    -- transcribed here are read off the commit that removed the constants.
    local was = {
        refresh_interval_ms  = 20,
        idle_flush_ms        = 35,
        reconcile_delay_ms   = 2000,
        jitter_floor_sq      = 4,
        live_highlight_tint  = 100,
        eraser_radius        = 12,
        erase_repaint_ms     = 70,
        drag_repaint_ms      = 60,
        lasso_sample_spacing = 12,
        frame_margin         = 10,
        hold_travel_sq       = 64,
        hold_delay_ms        = 350,
        rect_angle_tolerance = 18,
        palm_grace_ms        = 600,
        max_pen_speed        = 6,
        jump_base            = 48,
        max_jump_gap_ms      = 120,
        outlier_limit        = 8,
    }
    for key, value in pairs(was) do
        assertTrue(Tuning.spec[key], key .. " is gone from the spec")
        assertEq(Tuning.spec[key].default, value, key)
    end
    -- And nothing was added to the spec without being accounted for here.
    for key in pairs(Tuning.spec) do
        assertTrue(was[key] ~= nil, key .. " is in the spec but not in this list")
    end
end)
```

- [ ] **Step 2: Esegui e verifica che passi già**

```bash
cd lua && luajit spec/tuning.lua
```

Atteso: PASS. Questo test descrive lo stato di partenza — è un'ancora, non un obiettivo. Il suo valore è che dopo la sostituzione dello Step 3 deve **continuare** a passare.

- [ ] **Step 3: Sostituisci le costanti in `canvas.lua`**

Aggiungi, tra i `require` in cima (in ordine alfabetico, quindi dopo `Template` e prima di `UIManager`):

```lua
local Tuning = require("tuning")
```

Cancella queste dichiarazioni e i loro commenti (le righe 51-156 circa): `REFRESH_INTERVAL_MS`, `IDLE_FLUSH_MS`, `RECONCILE_DELAY_MS`, `LIVE_HIGHLIGHT_TINT`, `ERASER_RADIUS`, `MAX_PEN_SPEED`, `JUMP_BASE`, `MAX_JUMP_GAP_MS`, `OUTLIER_LIMIT`, `HOLD_TRAVEL_SQ`, `JITTER_FLOOR_SQ`, `PALM_GRACE_MS`, `ERASE_REPAINT_MS`, `DRAG_REPAINT_MS`, e a riga 505 `FRAME_MARGIN`.

Al loro posto, un solo commento:

```lua
-- The numbers that decide how the pen feels live in `tuning.lua`, one place,
-- each with the range it may take and the reason it is what it is. They are
-- read as `Tuning.<name>` at the point of use: one hash lookup per pen sample,
-- against a blit and an ioctl.
```

Poi sostituisci ogni uso. Sono questi, e sono tutti:

| Era | Diventa |
| --- | --- |
| `REFRESH_INTERVAL_MS` | `Tuning.refresh_interval_ms` |
| `IDLE_FLUSH_MS` | `Tuning.idle_flush_ms` |
| `RECONCILE_DELAY_MS` | `Tuning.reconcile_delay_ms` |
| `LIVE_HIGHLIGHT_TINT` | `Tuning.live_highlight_tint` |
| `ERASER_RADIUS` | `Tuning.eraser_radius` |
| `MAX_PEN_SPEED` | `Tuning.max_pen_speed` |
| `JUMP_BASE` | `Tuning.jump_base` |
| `MAX_JUMP_GAP_MS` | `Tuning.max_jump_gap_ms` |
| `OUTLIER_LIMIT` | `Tuning.outlier_limit` |
| `HOLD_TRAVEL_SQ` | `Tuning.hold_travel_sq` |
| `JITTER_FLOOR_SQ` | `Tuning.jitter_floor_sq` |
| `PALM_GRACE_MS` | `Tuning.palm_grace_ms` |
| `ERASE_REPAINT_MS` | `Tuning.erase_repaint_ms` |
| `DRAG_REPAINT_MS` | `Tuning.drag_repaint_ms` |
| `FRAME_MARGIN` | `Tuning.frame_margin` |

Trovali tutti con:

```bash
cd lua && grep -n "REFRESH_INTERVAL_MS\|IDLE_FLUSH_MS\|RECONCILE_DELAY_MS\|LIVE_HIGHLIGHT_TINT\|ERASER_RADIUS\|MAX_PEN_SPEED\|JUMP_BASE\|MAX_JUMP_GAP_MS\|OUTLIER_LIMIT\|HOLD_TRAVEL_SQ\|JITTER_FLOOR_SQ\|PALM_GRACE_MS\|ERASE_REPAINT_MS\|DRAG_REPAINT_MS\|FRAME_MARGIN" canvas.lua
```

**Due punti che non sono una sostituzione meccanica.**

Primo, `ERASER_RADIUS` è usato anche come valore iniziale del campo `eraser_size` nella dichiarazione della classe, a riga 161:

```lua
eraser_size = ERASER_RADIUS,
```

Quella riga viene eseguita quando il modulo si carica, cioè prima che `Tuning.load` abbia letto qualcosa. Diventa:

```lua
    eraser_size = Tuning.spec.eraser_radius.default,
```

cioè il default, non il valore tarato: `eraser_size` è un'impostazione dell'utente con la sua persistenza, e `notebook.lua:389` la sovrascrive comunque al caricamento. Il parametro `eraser_radius` del dock e il campo `eraser_size` del canvas sono due cose diverse che partono dallo stesso numero, ed è giusto che restino separate.

Secondo, il ritardo dello snap. In `_onPenMove` c'è un letterale senza nome:

```lua
                UIManager:scheduleIn(0.35, self.shape_snap_cb)
```

Diventa:

```lua
                UIManager:scheduleIn(Tuning.hold_delay_ms / 1000, self.shape_snap_cb)
```

- [ ] **Step 4: Sostituisci in `lasso.lua` e `shape.lua`**

In `lua/lasso.lua`, cancella il blocco di commento e la dichiarazione `local SAMPLE_SPACING = 12` (righe 30-40), aggiungi `local Tuning = require("tuning")` accanto agli altri require in cima, e sostituisci ogni `SAMPLE_SPACING` con `Tuning.lasso_sample_spacing`.

In `lua/shape.lua`, cancella `local RECT_ANGLE_TOLERANCE = 18` (riga 239), aggiungi `local Tuning = require("tuning")` accanto a `local Stroke = require("stroke")`, e sostituisci l'uso a riga 258 con `Tuning.rect_angle_tolerance`.

- [ ] **Step 5: Esegui tutto il banco di prova**

```bash
make verify
```

Atteso: lint pulito e **ogni** suite passata. Le suite `shape`, `lasso`, `lassoedit`, `eraser` e `palm` esercitano proprio il codice appena toccato: se una di loro cambia risultato, una sostituzione è sbagliata. Non proseguire finché non sono tutte verdi.

- [ ] **Step 6: Verifica che nessuna costante sia rimasta indietro**

```bash
cd lua && grep -n "^local [A-Z_]* = [0-9]" canvas.lua lasso.lua shape.lua
```

Atteso: nessun output.

- [ ] **Step 7: Commit**

```bash
git add lua/canvas.lua lua/lasso.lua lua/shape.lua lua/spec/tuning.lua
git commit -m "tuning: canvas, lasso e shape leggono i parametri dal modulo

Le costanti locali spariscono e i loro commenti si spostano su tuning.lua,
che diventa il posto unico dove sta scritto cosa fa ogni numero. Il ritardo
dello snap, che era uno 0.35 in mezzo a _onPenMove, prende finalmente un
nome. Comportamento invariato: i default sono gli stessi numeri, e un test
li confronta uno a uno."
```

---

### Task 3: Il dock

Il pannello. Si costruisce da `Tuning.tabs`, quindi aggiungere una manopola in futuro è aggiungere una riga in `tuning.lua` e non toccare questo file.

**File:**
- Crea: `lua/tuningdock.lua`
- Crea: `lua/spec/tuningdock.lua`
- Modifica: `Makefile:26` (`SUITES`)

**Interfacce:**
- Consuma: `Tuning.tabs`, `Tuning.spec`, `Tuning[key]`, `Tuning.set`, `Tuning.reset`, `Tuning.resetAll`, `Tuning.dump` dal Task 1; `Widgets.iconButton` da `lua/widgets.lua`.
- Produce:
  - `TuningDock:new{ width=n, height=n, canvas=<Canvas>, on_tab=function(id) }` — widget
  - `TuningDock.HEIGHT_RATIO = 0.34` — quanto dello schermo prende, letto dal Task 4 per calcolare la fascia
  - `TuningDock:setTab(id)`

Il dock riceve il `canvas` per la sola riga `eraser_mode`, che non è un parametro di `Tuning` ma un'impostazione del canvas (vedi Task 1). Se `canvas` è `nil` quella riga non compare — è così che il test lo costruisce senza un canvas vero.

- [ ] **Step 1: Scrivi la suite di test, che fallisce**

Crea `lua/spec/tuningdock.lua`:

```lua
#!/usr/bin/env luajit
--[[--
Tests for the tuning dock's wiring.

What can be checked without a panel is the arithmetic and the plumbing: that a
step lands on the value, that the ends of a range hold, that the tabs are the
ones the tuning module declares, and that a tab built for every group does not
raise. What it looks like at 1860 px is the headless render's job.

Run with:  luajit spec/tuningdock.lua   (from the plugin directory)
--]]--

package.path = "./?.lua;./spec/?.lua;" .. package.path

local support = require("support")
local uistubs = require("uistubs")
support.installStubs()
uistubs.install({})

local passed, failed = 0, 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        io.write("  ok   ", name, "\n")
    else
        failed = failed + 1
        io.write("  FAIL ", name, "\n         ", tostring(err), "\n")
    end
end

local function assertEq(got, want, what)
    if got ~= want then
        error(string.format("%s: got %s, want %s", what or "value",
            tostring(got), tostring(want)), 2)
    end
end

local function assertTrue(v, what)
    if not v then error((what or "value") .. ": expected truthy, got " .. tostring(v), 2) end
end

local store = {
    kept = {},
    readSetting = function(self, k) return self.kept[k] end,
    saveSetting = function(self, k, v) self.kept[k] = v end,
    delSetting = function(self, k) self.kept[k] = nil end,
}
G_reader_settings = store

local Tuning = require("tuning")
local TuningDock = require("tuningdock")

local function dock()
    return TuningDock:new{ width = 800, height = 300 }
end

io.write("stepping a value\n")

test("plus adds one step, minus takes one away", function()
    Tuning.resetAll()
    local d = dock()
    local base = Tuning.refresh_interval_ms
    local step = Tuning.spec.refresh_interval_ms.step

    d:step("refresh_interval_ms", 1)
    assertEq(Tuning.refresh_interval_ms, base + step, "after plus")

    d:step("refresh_interval_ms", -1)
    assertEq(Tuning.refresh_interval_ms, base, "back where it started")
    Tuning.resetAll()
end)

test("stepping stops at the ends of the range instead of running off", function()
    Tuning.resetAll()
    local d = dock()
    local s = Tuning.spec.outlier_limit
    for _ = 1, 500 do d:step("outlier_limit", 1) end
    assertEq(Tuning.outlier_limit, s.max, "top of the range")
    for _ = 1, 500 do d:step("outlier_limit", -1) end
    assertEq(Tuning.outlier_limit, s.min, "bottom of the range")
    Tuning.resetAll()
end)

test("a step is saved, not just applied", function()
    Tuning.resetAll()
    local d = dock()
    d:step("palm_grace_ms", -1)
    assertEq(store.kept["notebook_tuning_palm_grace_ms"], Tuning.palm_grace_ms, "stored")
    Tuning.resetAll()
end)

io.write("the tabs\n")

test("every tab the tuning module declares can be built", function()
    -- A tab whose rows raise when built is a tab that takes the notebook down
    -- with it, and it would only be found by tapping it on the device.
    for _, tab in ipairs(Tuning.tabs) do
        local d = dock()
        local ok, err = pcall(function() d:setTab(tab.id) end)
        assertTrue(ok, tab.id .. " failed to build: " .. tostring(err))
        assertEq(d.tab, tab.id, "current tab")
    end
end)

test("it opens on the first tab", function()
    local d = dock()
    assertEq(d.tab, Tuning.tabs[1].id, "opening tab")
end)

test("an unknown tab is ignored rather than leaving the dock blank", function()
    local d = dock()
    d:setTab("a tab that does not exist")
    assertEq(d.tab, Tuning.tabs[1].id, "still on the first tab")
end)

io.write("reset\n")

test("reset tab puts back only that tab's parameters", function()
    Tuning.resetAll()
    local d = dock()
    Tuning.set("refresh_interval_ms", 40)   -- ink
    Tuning.set("palm_grace_ms", 0)          -- input
    d:setTab("ink")
    d:resetTab()
    assertEq(Tuning.refresh_interval_ms, Tuning.spec.refresh_interval_ms.default, "ink reset")
    assertEq(Tuning.palm_grace_ms, 0, "input untouched")
    Tuning.resetAll()
end)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
```

- [ ] **Step 2: Aggiungi la suite al Makefile**

```make
SUITES := run pages eraser palm safe i18n gallery shape lasso lassoedit migration tuning tuningdock
```

- [ ] **Step 3: Esegui e verifica che fallisca**

```bash
cd lua && luajit spec/tuningdock.lua
```

Atteso: FAIL — `module 'tuningdock' not found`.

- [ ] **Step 4: Scrivi `lua/tuningdock.lua`**

```lua
--[[--
The tuning dock.

A band along the bottom of the screen, with the page still above it, shown only
inside a notebook called `_tuning_`.

Not a dialog, and that is the whole point. What is being tuned here is how the
pen feels, and a modal panel cannot be used to tune it: while it is open you
cannot draw, so the loop is change a number, close, draw, reopen -- and by the
time you are drawing you are comparing against a memory of thirty seconds ago.
With the band open you change a number and put a line down an inch higher, and
the difference is in the same hand.

Steppers rather than sliders, deliberately. Dragging a slider on E-Ink fires a
burst of partial refreshes, which is exactly the phenomenon being measured: the
instrument would contaminate the reading. And a slider gives you "about 47" when
what you need is the number to type into the source. A tap is one step, one
refresh, one exact value.

Built from `Tuning.tabs`, so adding a knob later is a line in `tuning.lua` and
nothing here.

@module notebook.tuningdock
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local Tuning = require("tuning")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Safe = require("safe")

local Screen = Device.screen

--[[--
How much of the screen the band takes.

A third. Less and the five rows of the longest tab do not fit without
scrolling, and a dock you have to scroll costs the tap it was meant to save.
More and there is not enough page left to write the sentence you are judging.
--]]
local HEIGHT_RATIO = 0.34

--- A tappable label, which is every control in here.
local Tappable = InputContainer:extend{
    text = nil,
    width = nil,
    selected = false,
    callback = nil,
    hold_callback = nil,
}

function Tappable:init()
    self.frame = FrameContainer:new{
        background = self.selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_BLACK,
        bordersize = Size.border.thin,
        radius = Size.radius.button,
        margin = 0,
        padding = Size.padding.small,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = Screen:scaleBySize(40) },
            TextWidget:new{
                text = self.text,
                face = Font:getFace("cfont", 16),
                fgcolor = self.selected and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
                max_width = self.width,
            },
        },
    }
    self[1] = self.frame
    self.dimen = self.frame:getSize()
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function Tappable:onTap()
    if self.callback then self.callback() end
    return true
end

function Tappable:onHold()
    if self.hold_callback then self.hold_callback() end
    return true
end

-- The dock ---------------------------------------------------------------------

local TuningDock = InputContainer:extend{
    width = nil,
    height = nil,
    -- Only for the eraser_mode row, which is a canvas setting rather than a
    -- tuning parameter. Absent in the test bench, and then the row is absent too.
    canvas = nil,
    -- Called with the tab id when it changes, so the owner can remember it.
    on_tab = nil,
    tab = nil,
}

TuningDock.HEIGHT_RATIO = HEIGHT_RATIO

function TuningDock:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.tab = self.tab or Tuning.tabs[1].id
    self:_build()
end

--[[--
How far a tap on plus moves the value.

Times ten on a hold, because a range like reconcile_delay_ms is 200 to 5000 in
steps of 100, and crossing it a tap at a time is forty-eight taps.
--]]
function TuningDock:step(key, direction, fast)
    local s = Tuning.spec[key]
    if not s then return end
    local mult = fast and 10 or 1
    Tuning.set(key, Tuning[key] + direction * s.step * mult)
    self:_refresh()
end

function TuningDock:setTab(id)
    for _, tab in ipairs(Tuning.tabs) do
        if tab.id == id then
            self.tab = id
            if self.on_tab then self.on_tab(id) end
            self:_refresh()
            return
        end
    end
    -- An id from a stored preference that no longer names a tab: leave the dock
    -- on the one it is on rather than showing an empty band.
end

function TuningDock:resetTab()
    for _, tab in ipairs(Tuning.tabs) do
        if tab.id == self.tab then
            for _, key in ipairs(tab.keys) do Tuning.reset(key) end
        end
    end
    self:_refresh()
end

function TuningDock:resetAll()
    Tuning.resetAll()
    self:_refresh()
end

--[[--
Writes the changed parameters to the log.

The log is the one channel that already exists -- `tools/restart.sh --log` reads
it -- and it is also the only one that survives the device being picked up and
put down. What it cannot do is be seen from the device, hence the confirmation.
--]]
function TuningDock:dump()
    local text = Tuning.dump()
    io.write("\nnotebook tuning:\n", text, "\n\n")
    io.flush()
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = "Tuning written to the log", timeout = 2 })
end

function TuningDock:_build()
    local content = VerticalGroup:new{ align = "left" }
    local inner_w = self.width - 2 * Size.padding.large

    -- The banner. Fixed, unerasable, and shown exactly in the condition it
    -- warns about: a notebook that is named _tuning_ whether or not that was
    -- meant.
    table.insert(content, TextWidget:new{
        text = "Test notebook - rename it if you are not tuning",
        face = Font:getFace("cfont", 15),
        max_width = inner_w,
    })

    table.insert(content, self:_tabRow(inner_w))
    table.insert(content, self:_commandRow(inner_w))

    for _, tab in ipairs(Tuning.tabs) do
        if tab.id == self.tab then
            for _, key in ipairs(tab.keys) do
                table.insert(content, self:_paramRow(key, inner_w))
            end
            if tab.id == "eraser" and self.canvas then
                table.insert(content, self:_eraserModeRow(inner_w))
            end
        end
    end

    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_BLACK,
        bordersize = Size.border.thin,
        radius = 0,
        padding = Size.padding.large,
        content,
    }
    self[1] = self.frame
end

function TuningDock:_tabRow(inner_w)
    local row = HorizontalGroup:new{ align = "center" }
    local n = #Tuning.tabs
    local cell = math.floor((inner_w - (n - 1) * Size.padding.small) / n)
    for i, tab in ipairs(Tuning.tabs) do
        if i > 1 then
            table.insert(row, HorizontalSpan:new{ width = Size.padding.small })
        end
        local id = tab.id
        table.insert(row, Tappable:new{
            text = tab.label,
            width = cell,
            selected = id == self.tab,
            callback = function() self:setTab(id) end,
        })
    end
    return row
end

function TuningDock:_commandRow(inner_w)
    local row = HorizontalGroup:new{ align = "center" }
    local commands = {
        { text = "Reset tab", fn = function() self:resetTab() end },
        { text = "Reset all", fn = function() self:resetAll() end },
        { text = "Dump",      fn = function() self:dump() end },
    }
    local cell = math.floor((inner_w - 2 * Size.padding.small) / 3)
    for i, c in ipairs(commands) do
        if i > 1 then
            table.insert(row, HorizontalSpan:new{ width = Size.padding.small })
        end
        table.insert(row, Tappable:new{ text = c.text, width = cell, callback = c.fn })
    end
    return row
end

--[[--
One parameter: `[-]  name  value  [+]`.

The name is shown as it is written in the source, underscores and all, because
what this panel is for is finding a number to type into that source: a prettier
label would be one more thing to translate back by hand at the end.
--]]
function TuningDock:_paramRow(key, inner_w)
    local btn_w = Screen:scaleBySize(64)
    local label_w = inner_w - 2 * btn_w - 2 * Size.padding.small
    local changed = Tuning[key] ~= Tuning.spec[key].default
    local row = HorizontalGroup:new{ align = "center" }

    table.insert(row, Tappable:new{
        text = "-", width = btn_w,
        callback = function() self:step(key, -1) end,
        hold_callback = function() self:step(key, -1, true) end,
    })
    table.insert(row, HorizontalSpan:new{ width = Size.padding.small })
    table.insert(row, CenterContainer:new{
        dimen = Geom:new{ w = label_w, h = Screen:scaleBySize(40) },
        TextWidget:new{
            -- A star on anything that is no longer at its default, so what has
            -- to be written down at the end can be seen at a glance.
            text = string.format("%s%s  %s", changed and "* " or "",
                key, tostring(Tuning[key])),
            face = Font:getFace("cfont", 16),
            max_width = label_w,
        },
    })
    table.insert(row, HorizontalSpan:new{ width = Size.padding.small })
    table.insert(row, Tappable:new{
        text = "+", width = btn_w,
        callback = function() self:step(key, 1) end,
        hold_callback = function() self:step(key, 1, true) end,
    })
    return row
end

--[[--
The eraser's mode, which is not a tuning parameter.

It is a reader-facing setting with its own key and its own place in the settings
panel, and it does not belong in `tuning.lua` among the numbers. It is here
anyway because the eraser cannot be judged without switching between the two
modes, and walking out to the settings panel to do it costs the whole point of
an in-place dock.
--]]
function TuningDock:_eraserModeRow(inner_w)
    local row = HorizontalGroup:new{ align = "center" }
    local cell = math.floor((inner_w - Size.padding.small) / 2)
    local modes = {
        { text = "erase: whole strokes", value = "stroke" },
        { text = "erase: part of a stroke", value = "area" },
    }
    for i, m in ipairs(modes) do
        if i > 1 then
            table.insert(row, HorizontalSpan:new{ width = Size.padding.small })
        end
        local value = m.value
        table.insert(row, Tappable:new{
            text = m.text,
            width = cell,
            selected = self.canvas.eraser_mode == value,
            callback = function()
                self.canvas.eraser_mode = value
                self:_refresh()
            end,
        })
    end
    return row
end

--[[--
Rebuilds the band and repaints it, and nothing else.

The page above is not in the dirty rectangle: what was written up there while
tuning has to stay legible across a hundred taps down here, and asking for it to
be repainted would flash it every time.
--]]
function TuningDock:_refresh()
    self:_build()
    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

function TuningDock:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    InputContainer.paintTo(self, bb, x, y)
end

return Safe.widget(TuningDock, "tuningdock")
```

- [ ] **Step 5: Esegui la suite e verifica che passi**

```bash
cd lua && luajit spec/tuningdock.lua
```

Atteso: `7 passed, 0 failed`.

Se qualcosa fallisce con un errore su un widget mancante fra gli stub (per esempio `ui/widget/infomessage`), guarda cosa `lua/spec/uistubs.lua` registra già: la maggior parte c'è, e quello che manca si aggiunge lì con `leaf()`, che è il segnaposto usato per i widget la cui apparenza non conta.

- [ ] **Step 6: Verifica e commit**

```bash
make verify
```

Atteso: lint pulito, tutte le suite verdi.

```bash
git add lua/tuningdock.lua lua/spec/tuningdock.lua Makefile
git commit -m "tuning: il pannello, costruito da solo dalla dichiarazione dei tab

Steppers e non slider: trascinare uno slider su e-ink genera la raffica di
refresh che e' esattamente il fenomeno da misurare, e restituisce un 'circa
47' quando serve il numero da scrivere nel sorgente."
```

---

### Task 4: Il cancello

L'interruttore. Alla fine di questo task il pannello si apre su un dispositivo vero.

**File:**
- Modifica: `lua/notebook.lua:43-72` (`init`), `lua/notebook.lua:360-392` (le impostazioni)
- Crea: `lua/spec/tuninggate.lua`
- Modifica: `Makefile:26` (`SUITES`)

**Interfacce:**
- Consuma: `TuningDock:new{...}`, `TuningDock.HEIGHT_RATIO`, `TuningDock:setTab` dal Task 3; `Tuning.load` dal Task 1.
- Produce: `Notebook.tuning_dock` — il widget, o `nil` in ogni taccuino che non si chiama `_tuning_`.

- [ ] **Step 1: Scrivi il test del cancello, che fallisce**

Crea `lua/spec/tuninggate.lua`:

```lua
#!/usr/bin/env luajit
--[[--
Tests for what opens the tuning dock, and for what it does to the page.

The dock is a band across the bottom, which means the page is shorter while it
is open. That is fine in the notebook it is meant for and would be a silent
disaster anywhere else -- ink is stored in screen coordinates, so a page laid
out against the wrong rectangle is a page whose ink is in the wrong place. So
what is pinned here is the gate itself: exactly one title opens it, and every
other notebook gets the geometry it has always had.

Run with:  luajit spec/tuninggate.lua   (from the plugin directory)
--]]--

package.path = "./?.lua;./spec/?.lua;" .. package.path

local support = require("support")
local uistubs = require("uistubs")
support.installStubs()
uistubs.install({})

local passed, failed = 0, 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        io.write("  ok   ", name, "\n")
    else
        failed = failed + 1
        io.write("  FAIL ", name, "\n         ", tostring(err), "\n")
    end
end

local function assertEq(got, want, what)
    if got ~= want then
        error(string.format("%s: got %s, want %s", what or "value",
            tostring(got), tostring(want)), 2)
    end
end

local function assertTrue(v, what)
    if not v then error((what or "value") .. ": expected truthy, got " .. tostring(v), 2) end
end

G_reader_settings = {
    kept = {},
    readSetting = function(self, k) return self.kept[k] end,
    saveSetting = function(self, k, v) self.kept[k] = v end,
    delSetting = function(self, k) self.kept[k] = nil end,
}

local Device = package.loaded["device"]
Device.screen.bb = support.FakeBB.new(600, 800)
Device.screen.refreshFast = function() end
Device.screen.refreshUI = function() end
Device.screen.refreshPartial = function() end

local Document = require("document")
local Notebook = require("notebook")

local function notebookNamed(title)
    return Notebook:new{ document = Document:new("/tmp/gate.scribe"), title = title }
end

io.write("the gate\n")

test("a notebook called _tuning_ gets the dock", function()
    local nb = notebookNamed("_tuning_")
    assertTrue(nb.tuning_dock, "no dock")
end)

test("every other notebook does not", function()
    for _, title in ipairs({ "notes", "tuning", "_tuning", "tuning_", "_TUNING_", "" }) do
        local nb = notebookNamed(title)
        assertTrue(nb.tuning_dock == nil, "dock opened for " .. string.format("%q", title))
    end
end)

test("a notebook with no title at all does not raise", function()
    -- The title is passed in by whoever opens the notebook, so it can be
    -- missing, and a comparison against nil must not be a crash.
    local nb = notebookNamed(nil)
    assertTrue(nb.tuning_dock == nil, "dock opened for a nameless notebook")
end)

io.write("the page underneath\n")

test("an ordinary notebook has the geometry it always had", function()
    local nb = notebookNamed("notes")
    local toolbar_h = nb.canvas.content.y
    assertEq(nb.canvas.content.h, nb.dimen.h - toolbar_h, "content height")
end)

test("the tuning notebook gives up a band at the bottom", function()
    local plain = notebookNamed("notes")
    local tuned = notebookNamed("_tuning_")
    assertTrue(tuned.canvas.content.h < plain.canvas.content.h, "page was not shortened")
    assertEq(tuned.canvas.content.y, plain.canvas.content.y, "top is unchanged")
    -- The page and the band together are the screen, with nothing left over and
    -- nothing overlapping: ink painted into a gap would be ink under the dock.
    assertEq(tuned.canvas.content.y + tuned.canvas.content.h + tuned.tuning_dock.height,
        tuned.dimen.h, "page plus band is not the screen")
end)

io.write("the remembered tab\n")

test("the tab is remembered across openings", function()
    local first = notebookNamed("_tuning_")
    first.tuning_dock:setTab("lasso")
    local second = notebookNamed("_tuning_")
    assertEq(second.tuning_dock.tab, "lasso", "reopened on a different tab")
end)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
```

- [ ] **Step 2: Aggiungi la suite al Makefile**

```make
SUITES := run pages eraser palm safe i18n gallery shape lasso lassoedit migration tuning tuningdock tuninggate
```

- [ ] **Step 3: Esegui e verifica che fallisca**

```bash
cd lua && luajit spec/tuninggate.lua
```

Atteso: FAIL — `no dock`, perché `Notebook` non conosce ancora `tuning_dock`.

- [ ] **Step 4: Aggancia il dock in `notebook.lua`**

Accanto agli altri `require` in cima:

```lua
local Tuning = require("tuning")
local TuningDock = require("tuningdock")
```

Sotto la riga `local SettingsDialog = require("settings")` — o comunque vicino alle altre costanti di modulo — aggiungi:

```lua
--[[--
The title that opens the tuning dock.

A notebook rather than a hidden gesture or a file on the device: it is made and
unmade from the gallery, with no SSH and nothing to remember, and a multi-tap
gesture on this digitizer is the kind of thing that fires by itself. The
notebook that carries the dock is also the notebook whose pages have the odd
geometry, which keeps both facts in one place.
--]]
local TUNING_TITLE = "_tuning_"
```

In `Notebook:init`, sostituisci il blocco che costruisce il canvas (righe 50-63 circa) con:

```lua
    -- The system status bar (clock, battery) is drawn over whatever is on
    -- screen, including us. Leaving a band clear at the top keeps it from
    -- landing on top of the toolbar buttons and covering them.
    local toolbar_h = self.toolbar:getSize().h + TOP_INSET

    -- The tuning dock takes a band off the bottom, by the same mechanism the
    -- toolbar takes one off the top: `content` is what the canvas will accept
    -- ink into, so shortening it is all there is to it.
    local dock_h = 0
    if self.title == TUNING_TITLE then
        Tuning.load()
        dock_h = math.floor(self.dimen.h * TuningDock.HEIGHT_RATIO)
    end

    self.canvas = Canvas:new{
        document = self.document,
        owner = self,
        content = Geom:new{
            x = 0,
            y = toolbar_h,
            w = self.dimen.w,
            h = self.dimen.h - toolbar_h - dock_h,
        },
        on_change = function() self:_onDocumentChanged() end,
        on_page_swipe = function(delta) self:_turnPage(delta) end,
    }
    self:_loadSettings()

    if dock_h > 0 then
        self.tuning_dock = TuningDock:new{
            width = self.dimen.w,
            height = dock_h,
            canvas = self.canvas,
            tab = G_reader_settings:readSetting(SETTING_PREFIX .. "tuning_tab"),
            on_tab = function(id)
                G_reader_settings:saveSetting(SETTING_PREFIX .. "tuning_tab", id)
            end,
        }
    end

    -- Both children are listed so that events reach them: a container only
    -- dispatches to its numbered children, and painting them by hand in
    -- paintTo is not enough to make their buttons tappable.
    -- The toolbar comes first so it gets a chance at a tap before the canvas,
    -- and the dock before both: it is in front of everything it overlaps.
    self[1] = self.toolbar
    self[2] = self.canvas
    if self.tuning_dock then
        table.insert(self, 1, self.tuning_dock)
    end
```

`SETTING_PREFIX` è dichiarato più in basso nel file, a riga 362, e in Lua un `local` non è visibile prima della sua dichiarazione: **spostalo in cima al file**, accanto a `TUNING_TITLE`. È l'unica modifica strutturale del task, e va fatta o `init` leggerebbe un `nil` globale. Verifica con `grep -n "SETTING_PREFIX" lua/notebook.lua` che tutti gli usi restino sotto la dichiarazione.

- [ ] **Step 5: Dipingi il dock in fondo**

Il container dipinge i figli numerati dall'origine, e il dock invece deve stare in fondo. Il dock resta fra i figli — è come i tap lo raggiungono — e si sposta da sé, portandosi dietro il proprio offset.

Nel blocco dello Step 4, quando il dock viene costruito, digli dove va:

```lua
    if self.tuning_dock then
        -- Listed so taps reach it: a container only dispatches to its numbered
        -- children. Where it lands is its own business -- see its paintTo --
        -- because the container would otherwise paint it at the origin, on top
        -- of the toolbar.
        self.tuning_dock.paint_offset_y = self.dimen.h - self.tuning_dock.height
        table.insert(self, 1, self.tuning_dock)
    end
```

e in `lua/tuningdock.lua` sostituisci la `paintTo` scritta nel Task 3 con:

```lua
--[[--
Paints the band where it belongs, not where the container would put it.

The owner paints its children from the origin, and this one goes at the bottom.
Carrying the offset here rather than painting the dock by hand from the owner
keeps it a child in both senses -- painted by the container, reached by taps --
instead of a widget the owner has to remember twice.
--]]
function TuningDock:paintTo(bb, x, y)
    y = y + (self.paint_offset_y or 0)
    -- Recorded after the offset, because this is the rectangle taps are matched
    -- against and the one _refresh asks to be repainted.
    self.dimen.x, self.dimen.y = x, y
    InputContainer.paintTo(self, bb, x, y)
end
```

`Notebook` non ha bisogno di una `paintTo` propria: non aggiungerla.

- [ ] **Step 6: Esegui la suite e verifica che passi**

```bash
cd lua && luajit spec/tuninggate.lua
```

Atteso: `6 passed, 0 failed`.

Costruire un `Notebook` intero sotto gli stub tira dentro la toolbar e le sue icone, che `lua/spec/lassoedit.lua` già fa: se manca uno stub, copia da lì la riga che lo registra. Non allargare `uistubs.lua` più del necessario — uno stub troppo indulgente è un test che passa su un dispositivo dove il plugin si pianta.

- [ ] **Step 7: Verifica tutto, e guarda la banda alla geometria vera**

```bash
make verify
```

Atteso: lint pulito, tutte le suite verdi. In particolare `pages`, `gallery` e `run` toccano `Notebook`: se una cambia risultato, l'aggancio ha rotto qualcosa che c'era già.

Poi, se hai l'emulatore configurato, il render headless alla geometria del dispositivo — è il solo modo di vedere se a 1860 px la banda sborda:

```bash
cd lua && luajit spec/screens.lua
```

Cerca fra i `require` in cima a `lua/spec/screens.lua` come le altre schermate vengono renderizzate e aggiungi il taccuino `_tuning_` allo stesso elenco. Se l'emulatore non è configurato la suite si salta da sola, e questo passo va rimandato alla prova sul dispositivo.

- [ ] **Step 8: Commit**

```bash
git add lua/notebook.lua lua/tuningdock.lua lua/spec/tuninggate.lua Makefile
git commit -m "tuning: il dock si apre in un taccuino chiamato _tuning_

Prende una fascia in fondo restringendo canvas.content, con lo stesso
meccanismo che la toolbar usa in cima. Ogni altro taccuino ha la geometria
di sempre, e un test lo fissa: l'inchiostro sta in coordinate schermo, e
una pagina disegnata contro il rettangolo sbagliato ha l'inchiostro nel
posto sbagliato."
```

---

### Task 5: Provalo sul dispositivo

Il task che dà il senso a tutti gli altri. Non ha test perché è il test.

**File:** nessuno. Se ne esce con dei numeri.

- [ ] **Step 1: Installa**

```bash
make deploy TARGET=root@<ip-del-kindle> FLAGS=--restart
```

- [ ] **Step 2: Crea il taccuino**

Dalla galleria, nuovo taccuino, titolo esattamente `_tuning_`. Aprilo: la banda dev'esserci, con il banner e cinque tab.

- [ ] **Step 3: Controlla che non sia comparsa altrove**

Apri un taccuino qualunque diverso. Nessuna banda, pagina alta come sempre. Se compare, il cancello è rotto e non si va avanti.

- [ ] **Step 4: Taratura, un tab per sessione**

Un parametro alla volta, e dopo ognuno lo stesso gesto: scrivi una riga di testo normale, non uno scarabocchio. Le differenze si sentono sulla scrittura vera.

Le due domande che hanno motivato tutto questo:

- **Gomma.** Tab Eraser, modalità "part of a stroke", cancella metà di una parola scritta a penna sopra a un'altra. Scendi con `erase_repaint_ms` (70 → 40 → 24 → 16) e poi sali (100, 150). Se esiste un valore che la rende fluida, l'hai trovato. Se invece non migliora mai — o peggiora in entrambe le direzioni — la causa non è questo numero ma **quanto lavoro costa una singola applicazione**, ed è una spec a parte.
- **Lazo.** Tab Lasso, seleziona un blocco denso di scrittura e trascinalo **in diagonale**, che è il caso peggiore. Muovi `drag_repaint_ms` in entrambe le direzioni. Attenzione al segnale specifico: **se alzarlo peggiora**, la causa è `Canvas:_dragStep`, che ridipinge l'unione del rettangolo lasciato e di quello occupato — passi più radi significano rettangoli più grandi, e nessun valore di questo numero può salvarlo. Anche quella è una spec a parte.

- [ ] **Step 5: Porta fuori i numeri**

Premi `Dump`, poi:

```bash
tools/restart.sh root@<ip-del-kindle> --log
```

Cerca `notebook tuning:` e copia le righe.

- [ ] **Step 6: Congela quello che hai trovato**

Riporta i valori nei `default` di `lua/tuning.lua`, aggiorna la lista `was` nel test di equivalenza in `lua/spec/tuning.lua` con gli stessi numeri (altrimenti fallisce, ed è esattamente il suo lavoro: nessun default cambia in silenzio), esegui `make verify`, e committa con una riga che dica **cosa hai sentito** e non solo cosa hai cambiato.

Poi, sul dispositivo, `Reset all`: da lì in avanti i default sono i tuoi, e il dock riparte da zero per la prossima volta.

---

## Cosa questo piano non fa

Non aggiusta la gomma né il trascinamento del lazo: li rende misurabili. Lo Step 4 del Task 5 dice quale osservazione fa la differenza fra "era un numero" e "è l'algoritmo", e nel secondo caso la spec da scrivere è già indicata.

Restano fuori, da brainstormare a parte: il tap lungo sulla penna per dimensioni e tipo di punta, e le frecce nel riconoscimento delle forme.
