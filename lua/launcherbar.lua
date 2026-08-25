--[[--
Optional integration with the Simple UI launcher's navigation bar.

Simple UI replaces KOReader's home screen and draws a bar of tabs along the
bottom. Anything shown over it -- our gallery included -- covers that bar, so
leaving the notebooks means going back before you can reach Library or Home.

Rather than patch Simple UI or guess at its geometry, this uses the extension
point it publishes: a widget registers a descriptor, and Simple UI wraps it with
the bar and resizes it to the area left over. If Simple UI is not installed, or
is a version without that API, nothing happens and the gallery stays fullscreen.

Reaching it needs care. Its modules are on its own package path, which is only
in effect while it loads, so `require` cannot find them from here. They are in
`package.loaded` afterwards, though, which is why registration is deferred until
the gallery is first opened rather than done at startup: plugin load order is
not something we control.

@module notebook.launcherbar
--]]--

local Safe = require("safe")
local logger = require("logger")

local LauncherBar = {}

local registered = false

--[[--
The names a quick action pointing at us can have recorded.

Simple UI stores the plugin a tab launches by the name KOReader knows it by,
which is the plugin directory's -- so a tab made against an earlier build of
this plugin names it whatever that directory was called. Both are recognised,
because a tab that quietly stops working after an update is worse than carrying
an extra string.
--]]
local PLUGIN_KEYS = { "notebook", "scribe" }

-- Our own dispatcher actions, for a tab configured that way instead. The second
-- is what the action was called in earlier builds.
local DISPATCHER_ACTIONS = { "notebook_open", "scribe_open" }

--- Simple UI's bottom bar, or nil.
local function bottombar()
    local bar = package.loaded["screens/sui_bottombar"]
    if type(bar) == "table" and type(bar.setTempTabActive) == "function" then
        return bar
    end
    return nil
end

--- Simple UI's core module, or nil if it is not loaded.
local function core()
    local ui = package.loaded["infra/sui_core"]
    if type(ui) == "table" and type(ui.BarInjection) == "table"
        and type(ui.BarInjection.register) == "function" then
        return ui
    end
    return nil
end

--[[--
Finds which tab of the launcher bar opens the notebooks, if any.

The bar marks the active tab itself, but only for a tab it has been told is the
active one -- which is why the notebooks were the one entry that never took the
black bar under it while Library, Home and the rest did.

The tab cannot be named in advance: it is a quick action the reader created, and
its id is whichever slot it happened to land in. So it is found by what it does
rather than by what it is called -- an action that launches this plugin, either
through the plugin hook or through our dispatcher action. Returns nil when the
reader has not put the notebooks on the bar at all, which is not an error: there
is then no tab to mark.
--]]
local function activeTabId()
    local store = package.loaded["infra/sui_store"]
    if type(store) ~= "table" or type(store.get) ~= "function" then return nil end

    local ok, ids = pcall(function() return store:get("simpleui_qa_list") end)
    if not ok or type(ids) ~= "table" then return nil end

    for _, id in ipairs(ids) do
        local got, cfg = pcall(function() return store:get("simpleui_qa_" .. id) end)
        if got and type(cfg) == "table" then
            for _, key in ipairs(PLUGIN_KEYS) do
                if cfg.plugin_key == key then return id end
            end
            for _, action in ipairs(DISPATCHER_ACTIONS) do
                if cfg.dispatcher_action == action then return id end
            end
        end
    end
    return nil
end

--[[--
Registers the gallery so the launcher bar stays visible underneath it.

Safe to call repeatedly; only the first call does anything. Everything is
wrapped, because this is a third-party API on a third-party plugin: if it
changes shape, the notebooks must keep working without it.
--]]
--[[--
Marks the notebooks tab as the active one while our screen is up.

Telling the bar which tab is active through the descriptor is not enough on its
own. Simple UI builds the bar around a widget *before* it asks the descriptor,
so the bar our screen is wrapped in has already been drawn with the previously
active tab marked; what the descriptor answers is then applied to the file
manager's bar, underneath, where nobody can see it. That is why the notebooks
were the one tab that never took the black bar.

`setTempTabActive` is the way out, and it is Simple UI's own: it is what the
Power tab uses for exactly this situation -- a screen that is active for as long
as it is open and then hands the tab back. It rebuilds the bar on every widget
in the stack, ours included.
--]]
function LauncherBar.markActive(widget, plugin)
    local bar = bottombar()
    local id = activeTabId()

    -- Said out loud, because all three are somebody else's and the failure is
    -- otherwise completely silent: the tab simply never lights up, and there is
    -- no way to tell which of the three went missing.
    if not bar or not id or not plugin then
        logger.warn("Notebook: cannot mark the notebooks tab --",
            "bar:", bar ~= nil, "tab:", tostring(id), "plugin:", plugin ~= nil)
        return
    end

    -- What was active before us. Simple UI has already recorded it on the
    -- widget by the time the injection callbacks run, and reading its own
    -- current value here would give our tab back, since it has just been set.
    widget._notebook_prev_action = widget._navbar_prev_action

    -- Also said out loud, and for the same reason as the failure above: the
    -- tab not lighting up looks identical whether this ran and did not take,
    -- or never ran at all, and those need different fixes.
    logger.info("Notebook: marking the notebooks tab", id,
        "-- was", tostring(widget._navbar_prev_action),
        "-- active", tostring(plugin.active_action))
    pcall(bar.setTempTabActive, plugin, id, true)

    --[[
    And again once the screen is on the stack.

    setTempTabActive rebuilds the bar on every widget UIManager is holding, so
    which widgets it reaches depends on when it is called -- and it is called
    from an injection callback, which runs while our screen is still being put
    up. A screen not yet on the stack is a screen whose own bar is not rebuilt:
    the file manager's, underneath and invisible, gets the mark instead.

    Repeating it a moment later costs a rebuild of a bar that is already
    correct in the case where the first call did reach us, and is the whole
    difference in the case where it did not. Scheduled through Safe.later
    rather than nextTick, which is the one scheduling pattern this plugin does
    not use: see spec/safe.lua.
    --]]
    Safe.later("launcherbar:mark", function()
        pcall(bar.setTempTabActive, plugin, id, true)
    end)
end

--- Hands the tab back when our screen closes.
function LauncherBar.unmarkActive(widget, plugin)
    local bar = bottombar()
    local id = activeTabId()
    if not bar or not id or not plugin then return end

    -- Only if the notebooks are still the active tab. If the reader has moved
    -- on -- which is usually *why* we are closing -- restoring here would undo
    -- the choice they just made.
    if plugin.active_action ~= id then return end
    pcall(bar.setTempTabActive, plugin, id, false, widget._notebook_prev_action)
end

function LauncherBar.register(widget_name)
    if registered then return true end

    local ui = core()
    if not ui then return false end

    local ok, err = pcall(function()
        ui.BarInjection.register{
            id = "notebook_gallery",
            widget_name = widget_name,
            -- The gallery pages through its cards itself, so the bar should not
            -- add its own pagination arrows.
            is_pageable = false,
            -- Worked out at the moment the bar asks, not now: the reader can
            -- move the tab, or add it, without restarting.
            get_active_action = function() return activeTabId() end,
            on_inject = function(widget, ctx)
                LauncherBar.markActive(widget, ctx and ctx.plugin)
            end,
            on_close = function(widget, ctx)
                LauncherBar.unmarkActive(widget, ctx and ctx.plugin)
            end,
        }
    end)

    if not ok then
        logger.warn("Notebook: could not register with the Simple UI bar:", err)
        return false
    end

    registered = true
    return true
end

--- True if the launcher bar is present and will wrap our screens.
function LauncherBar.available()
    return core() ~= nil
end

return LauncherBar
