-- Run from KOReader's disposable SDL runtime (tools/test-native-features.py).
require("setupkoenv")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(os.getenv("KO_HOME") .. "/settings.lua")

local Device = require("device")
require("document/canvascontext"):init(Device)
local root = assert(arg[1])
local plugin = root .. "/lua"
local load = dofile(plugin .. "/loader.lua")(plugin)

local Icon = require("ui/widget/iconwidget")
local icon_init = Icon.init
Icon.init = function(self)
    if self.icon and self.icon:match("^notebook%.") then
        self.file = plugin .. "/icons/" .. self.icon .. ".svg"
    end
    return icon_init(self)
end

local Screen = Device.screen
for _, name in ipairs({ "refreshUI", "refreshFast", "refreshFull", "refreshPartial" }) do
    Screen[name] = function() end
end

local UIManager = require("ui/uimanager")
local Document = load("document")
local Shape = load("shape")
local Notebook = load("notebook")
local Image = load("imageobject")
local Event = require("ui/event")
local time = require("ui/time")

local function tapAt(x, y)
    UIManager:sendEvent(Event:new("Gesture", {
        ges = "tap", pos = { x = x, y = y, w = 0, h = 0 },
    }))
end

local function findIcon(widget, icon, seen)
    if type(widget) ~= "table" then return nil end
    seen = seen or {}
    if seen[widget] then return nil end
    seen[widget] = true
    if widget.icon == icon then return widget end
    for i = 1, #widget do
        local found = findIcon(widget[i], icon, seen)
        if found then return found end
    end
end


local function center(widget)
    local d = assert(widget.dimen, "widget has no laid-out tap range")
    return math.floor(d.x + d.w / 2), math.floor(d.y + d.h / 2)
end

local function newNotebook(kind, zoom)
    local doc = Document:new("/tmp/selection-toolbar-" .. kind .. zoom .. ".scribe")
    doc:setTemplate("blank")
    local notebook = Notebook:new{ document = doc }
    notebook:paintTo(Screen.bb, 0, 0)
    UIManager:show(notebook)

    local canvas = notebook.canvas
    canvas:setZoom(zoom)
    local object
    if kind == "shape" then
        object = Shape.create("rectangle", 120, 350, 300, 500, 5, 0, true)
    else
        object = assert(Image.import(root .. "/tools/fixtures/reference.jpg", canvas.content))
    end
    doc:addStroke(object)
    notebook:paintTo(Screen.bb, 0, 0)
    canvas:_showLassoMenu({ object })
    local menu = canvas.lasso_menu
    menu:paintTo(Screen.bb, 0, 0)
    assert(menu and UIManager:getTopmostVisibleWidget() == menu, "lasso menu not on top")
    return notebook, canvas, object
end

local function closeNotebook(notebook)
    if notebook.canvas.lasso_menu then UIManager:close(notebook.canvas.lasso_menu) end
    UIManager:close(notebook)
end

for _, kind in ipairs({ "shape", "image" }) do
    for _, zoom in ipairs({ 1, 2 }) do
        -- A toolbar tool tap reaches the notebook under the floating lasso menu,
        -- even while the pen-up grace period would reject a canvas tap.
        local notebook, canvas = newNotebook(kind, zoom)
        local x, y = center(notebook.tool_buttons[2])
        canvas.pen_left_at = time.now()
        canvas.touch_rejected = true
        tapAt(x, y)
        assert(canvas.tool == "highlighter", kind .. " tool tap was not delivered")
        assert(not canvas.selected_strokes, kind .. " selection survived tool tap")
        closeNotebook(notebook)

        -- Non-tool actions share the same routing and finish the selection too.
        notebook, canvas = newNotebook(kind, zoom)
        x, y = center(assert(findIcon(notebook.toolbar_content, "notebook.refresh"), "refresh button not found"))
        canvas.pen_left_at = time.now()
        canvas.touch_rejected = true
        tapAt(x, y)
        assert(not canvas.selected_strokes, kind .. " selection survived refresh tap")
        closeNotebook(notebook)
    end
end

-- A tap inside the floating toolbar is consumed by that menu and does not fall
-- through to the notebook's tool buttons. Use the first shape-order control.
do
    local notebook, canvas = newNotebook("shape", 1)
    local menu = canvas.lasso_menu
    local control = menu.content_frame[1][1][1]
    local x, y = center(control)
    tapAt(x, y)
    assert(canvas.tool == "pen", "floating menu tap leaked to notebook toolbar")
    assert(canvas.selected_strokes, "floating menu action lost the selected shape")
    closeNotebook(notebook)
end

-- The notebook is active only under its floating lasso menu. A real modal
-- dialog above that menu still owns the tap and keeps the selection intact.
do
    local notebook, canvas = newNotebook("shape", 1)
    local x, y = center(notebook.tool_buttons[2])
    local modal = require("ui/widget/infomessage"):new{
        text = "Modal routing check", show_icon = false, timeout = 10,
    }
    UIManager:show(modal)
    assert(UIManager:getTopmostVisibleWidget() == modal, "modal dialog not on top")
    tapAt(x, y)
    assert(canvas.tool == "pen", "toolbar tap escaped through modal dialog")
    assert(canvas.selected_strokes, "modal dialog tap dismissed underlying selection")
    UIManager:close(modal)
    closeNotebook(notebook)
end

print("selection toolbar: shape/image at 1x/2x, tool/refresh routing, floating controls, and modal isolation passed")
