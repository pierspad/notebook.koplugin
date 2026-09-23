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
    live_highlight_refresh_ms = {
        default = 45, min = 20, max = 200, step = 5,
        doc = "Minimum gap between visible highlighter updates. The marker "
            .. "needs a grayscale waveform to remain visible while moving; "
            .. "spacing those slower updates keeps them from queuing behind the nib.",
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
        "jitter_floor_sq", "live_highlight_tint", "live_highlight_refresh_ms",
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
    return table.concat(out, "\n") .. "\n"
end

return Tuning
