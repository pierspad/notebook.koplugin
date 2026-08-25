--[[--
Handing a file to the LocalSend plugin, if it is installed.

Scribe does not implement the LocalSend protocol and does not ship it. There is
a separate plugin that does it properly -- a Go backend that both sends and
receives, with device discovery over multicast the way the phone apps do it --
and if the user has installed it, sending a notebook to a phone should be one
tap rather than a USB cable.

The connection is deliberately loose. Nothing here is `require`d, because a
require of a plugin that is not installed is a hard error at load; instead the
running plugin instance is looked up on the UI it registered itself with. If it
is not there, `available` says so and the caller leaves the button out. Scribe
works exactly as before with nothing installed.

@module notebook.share
--]]--

local DataStorage = require("datastorage")
local Library = require("library")
local lfs = require("libs/libkoreader-lfs")

local Share = {}

--[[--
Where the files being sent are put on their way out.

Sending several things at once means handing over one path, because that is
what LocalSend's send flow takes -- so they are staged into a directory and the
directory is what goes. A notebook has to be rendered to a PDF first in any
case: the .scribe format means nothing to a phone.

In KOReader's cache directory, which is the one place a plugin may leave things
it intends to be disposable. Not next to the notebooks: exporting is what makes
a PDF you meant to keep, and a copy made only so that something could be sent
should not end up in the gallery looking like one you asked for.
--]]
local STAGING_PREFIX = "notebook-send-"

local function cacheDir()
    return DataStorage:getDataDir() .. "/cache"
end

--- A fresh, empty directory to stage a send in, or nil if it cannot be made.
function Share.stagingDir()
    local path = cacheDir() .. "/" .. STAGING_PREFIX .. tostring(os.time())
    -- Two sends in the same second would otherwise share a directory and send
    -- each other's files.
    local n = 0
    while lfs.attributes(path, "mode") ~= nil do
        n = n + 1
        path = cacheDir() .. "/" .. STAGING_PREFIX .. tostring(os.time()) .. "-" .. n
    end
    return lfs.mkdir(path) and path or nil
end

--[[--
Removes staging directories left over from earlier sends.

Deleting one when its send finishes would be the obvious thing, and it is not
available: the send flow belongs to the other plugin, runs in the background,
and tells us nothing about how it ended. Deleting on a guess would mean pulling
a file out from under a transfer in progress.

So they are swept on the way in instead, and only once they are old enough that
nothing can still be reading them. An hour is far longer than any transfer over
a local network and far shorter than "forever", which is what the alternative
amounts to.
--]]
local SWEEP_AFTER_SECONDS = 3600

function Share.sweep()
    local dir = cacheDir()
    if lfs.attributes(dir, "mode") ~= "directory" then return end

    local now = os.time()
    for entry in lfs.dir(dir) do
        if entry:sub(1, #STAGING_PREFIX) == STAGING_PREFIX then
            local path = dir .. "/" .. entry
            local attr = lfs.attributes(path)
            if attr and attr.mode == "directory"
                and now - (attr.modification or 0) > SWEEP_AFTER_SECONDS then
                Library.deleteTree(path)
            end
        end
    end
end

-- The plugin declares itself as "LocalSend"; older packages of it used the
-- lowercase name, and either is registered on the UI under whatever it says.
local NAMES = { "LocalSend", "localsend" }

--[[--
The running LocalSend plugin, or nil.

Being registered is not enough on its own: the plugin has a recovery mode it
falls into when its backend binary is missing or does not match the device,
and in that state it loads and shows its menu but cannot send anything. Asking
for the method we actually intend to call keeps us out of that case.
--]]
local function plugin(ui)
    if not ui then return nil end
    for _, name in ipairs(NAMES) do
        local p = ui[name]
        if type(p) == "table" and type(p.showFileSendFlow) == "function" then
            return p
        end
    end
    return nil
end

--- True when there is a LocalSend plugin able to send a file.
function Share.available(ui)
    return plugin(ui) ~= nil
end

--[[--
Opens LocalSend's own send flow on `path`.

Its flow is the one to use rather than anything of ours: it scans for devices,
shows the picker, handles HTTPS and the PIN, and reports progress. We only say
which file.

Returns false if the plugin went away between the check and the call, which is
possible in principle -- the UI is rebuilt when a book is opened -- and costs a
line to survive.
--]]
function Share.send(ui, path)
    local p = plugin(ui)
    if not p then return false end
    p:showFileSendFlow(path)
    return true
end

return Share
