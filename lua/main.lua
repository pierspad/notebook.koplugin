--[[--
Notebook: handwriting notebooks for KOReader.

Stylus input arrives through KOReader's own stylus callback API, so nothing in
the framework or on the device is patched -- this plugin is purely additive.

The private loader keeps plugin modules separate from KOReader and sibling
plugins. It retains the plugin directory in each module environment, so later
callbacks can safely require their own modules after KOReader restores package.path.

@module koplugin.notebook
--]]--

local plugin_dir = assert(debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$"))
local require = assert(loadfile(plugin_dir .. "/loader.lua"))()(plugin_dir)

local Dispatcher = require("dispatcher")
local Document = require("document")
local Gallery = require("gallery")
local InfoMessage = require("ui/widget/infomessage")
local LauncherBar = require("launcherbar")
local Library = require("library")
local Notebook = require("notebook")
local Share = require("share")
local Updater = require("updater")
local Safe = require("safe")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local _ = require("i18n")

-- Common UI modules are resolved once through the private loader.
require("newnotebook")
require("template")
require("pagepanel")
require("papersample")
require("templatepicker")
require("rect")
require("widgets")

--[[--
Copies the plugin's icons into KOReader's user icon directory.

IconWidget resolves icons by name, and searches the data directory's `icons/`
folder before its own -- that is the supported way to add icons, and where other
plugins put theirs. Since the toolbar cannot draw without them, this runs on
load and re-copies anything missing, so the icons survive a KOReader upgrade
that wipes the data directory.
--]]
local installIcons = require("pluginicons")

-- The gallery currently on screen, if any. Held at module level because the
-- plugin is instantiated once per UI (file manager and reader each get one)
-- while there is only ever one notebook list.
local live_gallery = nil

local Scribe = require("ui/widget/container/widgetcontainer"):extend{
    name = "notebook",
    is_doc_only = false,
}

function Scribe:onDispatcherRegisterActions()
    Dispatcher:registerAction("notebook_open", {
        category = "none",
        event = "ScribeOpenNotebook",
        title = _("Open notebook"),
        general = true,
    })
end

function Scribe:init()
    -- Once per session rather than once per instance: this plugin is built for
    -- the file manager and again for the reader, and the second run finds
    -- nothing left to move.
    Library.migrateSettings()

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    installIcons()
    Updater.start(plugin_dir)
end

function Scribe:addToMainMenu(menu_items)
    menu_items.notebook = {
        text = _("Notebook"),
        sorting_hint = "more_tools",
        callback = function() self:openNotebook() end,
    }
end

function Scribe:onScribeOpenNotebook()
    self:openNotebook()
    return true
end

--- Opens the gallery: the list of notebooks, rather than one fixed notebook.
function Scribe:openNotebook()
    if Updater.installed or Updater.installing then
        UIManager:show(InfoMessage:new{ text = _("Restart KOReader to use the updated Notebook plugin.") })
        return
    end
    if Safe.failed then
        UIManager:show(InfoMessage:new{
            text = _("Notebook encountered an error. Restart KOReader to reopen it; see notebook-error.log for details."),
        })
        return
    end
    if not Library.ensureDir("") then
        UIManager:show(InfoMessage:new{
            text = _("Could not create the notebook folder."),
        })
        return
    end

    -- Ask the Simple UI launcher to keep its bar visible under the gallery.
    -- Done here rather than at startup: its modules only appear in
    -- package.loaded once it has loaded, and plugin order is not ours to pick.
    LauncherBar.register("notebook_gallery")

    --[[
    One gallery, however many times the notebooks are asked for.

    Every request used to build a new one and show it, so tapping the notebooks
    tab three times left three of them stacked on top of each other, each one
    covering the file manager underneath. They are fullscreen, so nothing showed
    that anything was wrong until a tab that opens the file manager appeared to
    do nothing at all.
    --]]
    if live_gallery and not live_gallery.closed then
        if UIManager:isWidgetShown(live_gallery) then
            -- Already the screen you are on. Asking for it again is not a
            -- reason to have two of it, and showing a widget that is already
            -- on the stack would put it there a second time.
            UIManager:setDirty(live_gallery, "ui")
            return
        end
        -- Built before but taken off the stack: put it back rather than
        -- rebuilding it, so it opens on the folder it was left in.
        UIManager:show(live_gallery, "ui")
        return
    end

    --[[
    Sending is offered only when the LocalSend plugin is there to do it.

    Asked here rather than at load: plugins are registered on the UI in an order
    that is not ours to pick, and by the time the notebooks are asked for they
    all are. Leaving the hook nil is what keeps the action off the header --
    the gallery has no notion of LocalSend beyond "there is somewhere to send
    this, or there is not".
    --]]
    local ui = self.ui
    local on_share = Share.available(ui) and function(path, options)
        Share.send(ui, path, options)
    end or nil

    local gallery
    gallery = Gallery:new{
        on_open = function(name, folder, template)
            self:_openByName(name, folder, gallery, template)
        end,
        on_share = on_share,
    }
    if Safe.failed or gallery.closed then return end
    live_gallery = gallery
    --[[
    Shown with an ordinary refresh, not the flashing one a fullscreen widget
    gets by default.

    A flash is worth its half-second before writing, which is why opening a
    notebook still asks for one: a clean panel is what the ghosting of the
    previous page would otherwise sit on. A grid of thumbnails is not written
    on, and arriving at it should feel like the launcher's other tabs, which do
    not flash.
    --]]
    UIManager:show(gallery, "ui")
end

function Scribe:_openByName(name, folder, gallery, template)
    local path = Library.pathFor(name, folder)
    local doc = Document:new(path)

    if lfs.attributes(path, "mode") == "file" then
        if not doc:load() then
            UIManager:show(InfoMessage:new{
                text = _("This notebook could not be opened; it may be from a newer version."),
                timeout = 5,
            })
            return
        end
    elseif template then
        -- A notebook being created: the paper chosen for it. Setting it marks
        -- the document dirty, so it is written out even if nothing is drawn.
        doc:setTemplate(template)
    end

    -- Shown with an explicit full refresh rather than leaving it to the widget.
    --
    -- The canvas paints straight into the framebuffer, outside UIManager's
    -- accounting, so UIManager cannot know how much of the screen is really
    -- ours. And what is on the panel at this moment depends on how we got here:
    -- coming from the new-notebook dialog, the refresh the closing dialog left
    -- behind covers only the rectangle the dialog occupied, so without this the
    -- notebook is painted into the buffer and the screen keeps showing the
    -- gallery. Saying it here, at the one place a notebook is opened, does not
    -- depend on which widget ends up handling the Show event.
    local notebook = Notebook:new{
        document = doc,
        title = name,
        -- Coming back should show the new modification time and, for a notebook
        -- that had never been saved before, the notebook itself.
        on_closed = function()
            if gallery then gallery:_rebuild() end
        end,
        -- Flashing, deliberately: what you are about to write on should not
        -- start out carrying the ghosts of the grid that was there a moment
        -- ago, and this is the one moment where half a second buys a clean
        -- page for the whole time you spend on it.
    }
    if not Safe.failed and not notebook.closed then UIManager:show(notebook, "full") end
end

return Scribe
