--[[--
Keeping a fault in this plugin from taking the device down with it.

A plugin runs inside KOReader's one and only event loop, and there are two ways
it can stop that loop dead. Both leave a Kindle that answers nothing at all --
no touch, no buttons, not even a redraw -- so the only way out is to hold the
power button. That is not an acceptable outcome for a notebook, however bad the
bug behind it: the worst this plugin should ever do is close itself.

**An error thrown anywhere the loop calls us.** Event handlers, `paintTo` and
scheduled callbacks are all invoked by UIManager, and the stylus callback is
invoked from deeper still, inside input polling. Nothing there is protected: a
`nil` indexed one level down in our code propagates all the way out and takes
KOReader with it.

**A unit of work that never gives the loop back.** `UIManager:handleInput` is

    repeat
        _checkTasks()
        _repaint()
    until not _task_queue_dirty

and input is only read *after* that loop settles. So a chain of `nextTick` tasks
that keeps re-arming itself, or a single Lua loop that never ends, means input
is never polled again. This is the mechanism behind every "the Kindle froze"
report, and it is why nothing in this plugin may schedule with `nextTick`: see
`Safe.later`.

What this module does about them:

  * `Safe.wrap` puts a pcall around anything the loop calls into.
  * `Safe.widget` applies that to every handler of a widget class at once.
  * `Safe.later` schedules follow-up work in a way that always yields to input.
  * `Safe.watched` bounds a call in VM instructions, so a runaway loop becomes a
    traceback naming the loop instead of a dead device.
  * `Safe.onShutdown` registers tear-down that has to run even when the fault
    has already switched the ordinary handlers off.

And when something does go wrong, `Safe.report` shuts the plugin down: it takes
the stylus callback back, closes our screens, writes a log the reader can send
on, and says so. KOReader carries on.

@module notebook.safe
--]]--

local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("i18n")
local T = require("ffi/util").template

local Safe = {}

--[[--
Delay used for follow-up work, in seconds.

Any value above zero is enough, and zero is not: a task scheduled for *now* is
due on the very next pass of the loop above, so the loop goes round again
without ever reaching the input poll. A task scheduled even a moment ahead is
not due, the loop settles, and input is read. The exact figure only decides how
quickly the next unit of work starts.
--]]
local YIELD = 0.01

-- Roughly a tenth of a second of Lua. Long enough that no legitimate handler
-- comes close, short enough that a runaway is caught before anyone reaches for
-- the power button.
local WATCHDOG_INSTRUCTIONS = 20000000
local WATCHDOG_BUDGET = 5

-- Set once we have shut down, so a fault that repeats on every event reports
-- once rather than putting a dialog up forever.
Safe.failed = false

--[[--
Work that has to happen on the way out, whether we are closing normally or
falling over.

Ordinary tear-down lives in `onCloseWidget`, and after a fault that handler
never runs: `Safe.report` raises `Safe.failed` before it closes anything, and
every wrapped `handleEvent` returns immediately from then on. That is deliberate
-- a fault that repeats on every event must not put a dialog up forever -- but it
means the one moment tear-down matters most is the one moment it is skipped.

Anything registered here is run by `Safe.report` directly, outside that gate.
Reserved for state that outlives the plugin: the canvas patches KOReader's own
input handlers while it is up, and leaving those in place is a reader whose pen
has stopped working until it is restarted.
--]]
local teardowns = {}

--- Registers `fn` to run if the plugin shuts down after a fault.
function Safe.onShutdown(key, fn)
    teardowns[key] = fn
end

--- Takes a registration back, once its owner has cleaned up by itself.
function Safe.clearShutdown(key)
    teardowns[key] = nil
end

--- Runs every registration once, in isolation: one failure must not strand the rest.
local function runTeardowns()
    for key, fn in pairs(teardowns) do
        teardowns[key] = nil
        pcall(fn)
    end
end

--- Where the crash log goes. Beside the notebooks, so it is easy to find over USB.
local function logPath()
    local ok, Library = pcall(require, "library")
    if ok and Library and Library.abs then
        local dir = Library.abs("")
        if dir then return dir .. "/notebook-error.log" end
    end
    return "/tmp/notebook-error.log"
end

--- Appends what happened to the log, so it can be sent on.
local function writeLog(where, err)
    local ok, file = pcall(io.open, logPath(), "a")
    if not ok or not file then return nil end
    pcall(function()
        file:write(string.format("\n=== %s\nin: %s\n%s\n",
            os.date("%Y-%m-%d %H:%M:%S"), tostring(where), tostring(err)))
        file:close()
    end)
    return logPath()
end

--- Closes every screen this plugin has on the stack.
local function closeScreens()
    local stack = UIManager._window_stack
    if not stack then return end
    -- Downwards, because closing removes entries.
    for i = #stack, 1, -1 do
        local widget = stack[i] and stack[i].widget
        if widget and widget.notebook_screen then
            pcall(function() UIManager:close(widget) end)
        end
    end
end

--[[--
Shuts the plugin down after a fault, as quietly as it can.

The order matters. The stylus callback goes first and unconditionally: it is
invoked from inside input polling, so if the fault is in there, every pen event
from now on would hit it again -- and there would be no way to put the pen down
that did not go through the broken code.
--]]
function Safe.report(where, err)
    if Safe.failed then return end
    Safe.failed = true

    logger.err("Notebook: shutting down after an error in", where, err)

    pcall(function()
        if Device.input and Device.input.unregisterStylusCallback then
            Device.input:unregisterStylusCallback()
        end
    end)

    -- Before the screens go, and not through them: closing a screen dispatches
    -- CloseWidget, and CloseWidget arrives through the handleEvent that
    -- Safe.failed has just switched off. See the note on Safe.onShutdown.
    runTeardowns()

    local path = writeLog(where, err)
    pcall(closeScreens)

    pcall(function()
        UIManager:show(InfoMessage:new{
            text = path
                and T(_("The notebook plugin hit a problem and has closed.\n\nKOReader itself is fine.\n\nDetails were written to:\n%1"), path)
                or _("The notebook plugin hit a problem and has closed.\n\nKOReader itself is fine."),
        })
    end)
end

--[[--
Runs `fn` with its arguments, reporting rather than propagating a failure.

Returns whatever `fn` returned, or nil after a fault. Callers that are event
handlers should treat nil as "not handled" -- by then the plugin is closing, so
there is nothing left to handle.
--]]
function Safe.call(where, fn, ...)
    if Safe.failed then return nil end
    local results = { pcall(fn, ...) }
    if results[1] then
        return unpack(results, 2, #results)
    end
    Safe.report(where, results[2])
    return nil
end

--- `fn` with the protection of Safe.call permanently around it.
function Safe.wrap(where, fn)
    if not fn and type(where) == "function" then
        fn = where
        where = "anonymous"
    end
    return function(...)
        return Safe.call(where, fn, ...)
    end
end

--[[--
Runs `fn` under a watchdog, so a loop that never ends becomes an error.

pcall does not help with a loop: nothing is thrown, the call simply never comes
back, and everything below it in the stack -- the event loop included -- waits
forever. A count hook is the only thing in Lua that can interrupt one.

**The hook alone is not enough on LuaJIT, and fails silently.** A count hook is
checked by the interpreter; it is not checked from inside a compiled trace. A
tight loop is exactly what LuaJIT compiles first, so the hook that was supposed
to catch a runaway is the one thing guaranteed not to see it -- verified here,
where `while true do n = n + 1 end` under a hook alone runs until it is killed.
Compilation has to be off for the guarded call, which is why this is used only
where the work is small and its speed does not matter.

Which means: handlers yes, drawing no. A tap that takes a few milliseconds can
afford to run interpreted; a pen sample that has to be on the panel within
twenty cannot, and neither can a repaint of a page of ink.
--]]
function Safe.watched(where, fn, ...)
    if Safe.failed then return nil end
    if debug.gethook() then
        -- Already inside a watched call; nesting hooks would only replace the
        -- outer one's budget with this one's.
        return Safe.call(where, fn, ...)
    end

    local budget = WATCHDOG_BUDGET
    debug.sethook(function()
        budget = budget - 1
        if budget <= 0 then
            debug.sethook()
            error(string.format(
                "watchdog: %s did not finish, and the device would have stopped "
                .. "answering\n%s", where, debug.traceback("", 2)), 0)
        end
    end, "", WATCHDOG_INSTRUCTIONS)
    if jit then pcall(jit.off) end

    local results = { pcall(fn, ...) }

    if jit then pcall(jit.on) end
    debug.sethook()

    if results[1] then
        return unpack(results, 2, #results)
    end
    Safe.report(where, results[2])
    return nil
end

--[[--
Schedules follow-up work, protected, and in a way that yields to input first.

This is the only way anything in this plugin may ask to be called back. Chaining
`UIManager:nextTick` is what keeps the loop from ever polling input; there is no
case in this plugin where a task is so urgent that the reader should not be able
to touch the screen before it runs.
--]]
function Safe.later(where, fn)
    if Safe.failed then return end
    if not fn and type(where) == "function" then
        fn = where
        where = "Safe.later"
    end
    UIManager:scheduleIn(YIELD, Safe.wrap(where, fn))
end

--[[--
Wraps the three ways the event loop enters a screen.

There are exactly three, and covering them covers everything the loop can reach:

  * `handleEvent` -- every gesture, and Show and CloseWidget too, arrive this
    way. A container dispatches to its children from inside it, so wrapping it
    here also covers a fault in any button anywhere in the tree.
  * `paintTo` -- called from the repaint pass.
  * `init` -- called while the screen is being built, before it is shown.

Each is resolved through the class, so an inherited one is wrapped just as an
overridden one is.

`handleEvent` additionally gets the watchdog. It is where a tap ends up, a tap
is supposed to be over in a moment, and a tap that never comes back is exactly
the failure this module exists to prevent. `paintTo` does not: the drawing path
runs through it thousands of times while writing, and taking LuaJIT off its
compiled traces there would cost more than it could ever save.

@tparam table class the widget class, as returned by `:extend`
@tparam string name what to call it in a log
@tparam[opt=true] boolean watch false to protect without the watchdog, for a
  class whose events are on the drawing path
--]]
function Safe.widget(class, name, watch)
    -- The marker is how a screen of ours is recognised on the window stack when
    -- there is a fault to clean up after; see closeScreens. Recognising them
    -- there rather than keeping a registry means there is no list that can
    -- disagree with what is actually on screen.
    class.notebook_screen = name

    local handle_event = class.handleEvent
    if handle_event then
        if watch == false then
            class.handleEvent = function(self, event)
                return Safe.call(name .. ":handleEvent", handle_event, self, event)
            end
        else
            class.handleEvent = function(self, event)
                return Safe.watched(name .. ":handleEvent", handle_event, self, event)
            end
        end
    end

    local paint_to = class.paintTo
    if paint_to then
        class.paintTo = function(self, bb, x, y)
            return Safe.call(name .. ":paintTo", paint_to, self, bb, x, y)
        end
    end

    local init = class.init
    if init then
        class.init = function(self)
            return Safe.call(name .. ":init", init, self)
        end
    end

    return class
end

--- The delay used between units of work, for anything that needs to match it.
Safe.YIELD = YIELD

return Safe
