-- Tool options and persisted canvas settings, independent of toolbar layout.
local ActionMenu = require("actionmenu")
local Device = require("device")
local SettingsDialog = require("settings")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local _ = require("i18n")
local Screen = Device.screen

return function(Notebook, TOOLS, SETTING_PREFIX)
-- Settings ---------------------------------------------------------------------

--- Persists a canvas setting and applies it immediately.
function Notebook:_setSetting(key, value)
    self.canvas[key] = value
    self.canvas:_debugEvent("setting:" .. key, nil, nil, nil, value)
    G_reader_settings:saveSetting(SETTING_PREFIX .. key, value)
end

function Notebook:_colorActions(key, index, show_section)
    local actions = {}
    for i, option in ipairs({
        {0, _("Black"), "black"}, {255, _("White"), "white"},
        {0x1E53935, _("Red"), "red"}, {0x11E88E5, _("Blue"), "blue"},
        {0x1FB8C00, _("Orange"), "orange"}, {0x143A047, _("Green"), "green"},
        {0x1FDD835, _("Yellow"), "yellow"}, {0x18E24AA, _("Purple"), "purple"},
    }) do
        local value = option[1]
        actions[#actions + 1] = {
            swatch = option[3], section = (show_section ~= false and i == 1) and _("Color") or nil,
            text = option[2], selected = function() return self.canvas[key] == value end,
            callback = function()
                self:_setSetting(key, value)
                self:_selectTool(index)
            end,
        }
    end
    return actions
end

function Notebook:_showPenOptions()
    self:_finishInteraction()
    local actions = {}
    for _index, option in ipairs({
        { "pen_style", "fineliner", _("Fineliner"), "notebook.fineliner" },
        { "pen_style", "fountain", _("Fountain pen"), "notebook.fountain" },
        { "pen_style", "pencil", _("Pencil"), "notebook.pencil" },
        { "line_style", "line", _("Line"), "notebook.line", _("Stroke style") },
        { "line_style", "arrow", _("Arrow"), "notebook.arrow" },
    }) do
        local key, value, label = option[1], option[2], option[3]
        table.insert(actions, {
            icon = option[4],
            section = option[5],
            text = label,
            selected = function() return self.canvas[key] == value end,
            callback = function()
                self:_setSetting(key, value)
                self:_selectTool(1)
            end,
        })
    end
    for _, action in ipairs(self:_colorActions("pen_color", 1)) do actions[#actions + 1] = action end
    self:_showToolMenu(1, _("Pen type"), actions, "pen_width")
end

function Notebook:_showToolMenu(index, title, actions, key)
    self:_finishInteraction()
    local menu
    local menu_width = math.min(self.dimen.w - 2 * Size.border.window,
        math.max(key and SettingsDialog.choiceRowWidth() or 0, Screen:scaleBySize(340)))
    local footer = key and SettingsDialog.sizeChoices(key, self.canvas[key], function(value)
        self:_setSetting(key, value)
        self.canvas.tool = TOOLS[index].tool
        if menu then UIManager:setDirty(menu, "ui", menu.panel.dimen) end
    end, menu_width)
    local text_size
    if TOOLS[index].tool == "text" then
        text_size = require("textsizepicker"):new{
            width=menu_width, canvas=self.canvas,
            on_change=function(value)
                self:_setSetting("text_size",value)
                if menu then UIManager:setDirty(menu,"ui",menu.panel.dimen) end
            end,
        }
    end
    menu = ActionMenu:new{
        header=text_size,
        row_height=text_size and Screen:scaleBySize(40) or nil,
        on_options_changed=text_size and function() text_size:updatePreview() end or nil,
        title=title, actions=actions, footer=footer,
        width=menu_width,
        anchor=self.tool_buttons[index].dimen,
        tool_buttons=self.tool_buttons,
        on_tool_options=function(next_index)
            UIManager:close(menu)
            self:_openToolOptions(next_index)
        end,
        draw_target=self.canvas,
        disable_double_tap=false,
    }
    UIManager:show(menu)
end

function Notebook:_showToolOptions(index)
    local tool = TOOLS[index].tool
    if tool == "pen" then return self:_showPenOptions() end
    if tool == "highlighter" then
        local colors = self:_colorActions("highlighter_color", index, false)
        return self:_showToolMenu(index, _("Color"), colors, "highlighter_width")
    end
    local actions = {}
    if tool == "eraser" then
        for _index, option in ipairs({{"stroke", _("Whole strokes")}, {"area", _("Part of a stroke")}}) do
            local value = option[1]
            table.insert(actions, {icon="notebook.eraser",
                text=option[2], selected=function() return self.canvas.eraser_mode == value end,
                callback=function() self:_setSetting("eraser_mode", value) end})
        end
        return self:_showToolMenu(index, _("Eraser type"), actions, "eraser_size")
    end
    if tool == "shape" then
        for _index, option in ipairs({
            {"square", _("Square")}, {"rectangle", _("Rectangle")},
            {"circle", _("Circle")}, {"triangle", _("Triangle")},
        }) do
            local kind = option[1]
            table.insert(actions, {icon="notebook." .. kind,
                text=option[2], selected=function() return self.canvas.shape_kind == kind end,
                callback=function() self:_setSetting("shape_kind", kind) end})
        end
        table.insert(actions, {icon="notebook.shape", section=_("Fill"),
            text=_("Filled shape"), selected=function() return self.canvas.shape_fill == true end,
            callback=function() self:_setSetting("shape_fill", not self.canvas.shape_fill) end})
        local colors = self:_colorActions("shape_color", index)
        for _, action in ipairs(colors) do actions[#actions + 1] = action end
        return self:_showToolMenu(index, _("Shapes"), actions)
    end
    if tool == "text" then
        for _index, option in ipairs({{"sans", _("Sans-serif"), "E", "cfont"},
                                  {"serif", _("Serif"), "E", "ffont"},
                                  {"mono", _("Monospace"), "M", "infont"}}) do
            table.insert(actions, {section=_index == 1 and _("Font family") or nil,
                icon_text=option[3], icon_font=option[4], icon_size=18, text=option[2],
                selected=function() return (self.canvas.text_font or "sans") == option[1] end,
                callback=function() self:_setSetting("text_font", option[1]) end})
        end
        for _index, option in ipairs({{"text_bold", _("Bold"), "B", true},
                                  {"text_italic", _("Italic"), "I"},
                                  {"text_underline", _("Underline"), "U̲"}}) do
            table.insert(actions, {section=_index == 1 and _("Text style") or nil,
                icon_text=option[3], icon_bold=option[4], text=option[2],
                selected=function() return self.canvas[option[1]] == true end,
                callback=function()
                    self:_setSetting(option[1], not self.canvas[option[1]])
                end})
        end
        for _index, option in ipairs({
            { true, _("White"), "notebook.bg-white", _("Background") },
            { false, _("Transparent"), "notebook.bg-none" },
        }) do
            local value = option[1]
            table.insert(actions, {
                icon=option[3], text=option[2], section=option[4],
                selected=function() return self.canvas.text_background == value end,
                callback=function() self:_setSetting("text_background", value) end,
            })
        end
        return self:_showToolMenu(index, _("Text options"), actions)
    end
end

for name, method in pairs(require("notebooktext")) do
    Notebook[name] = method
end

function Notebook:_showSettings()
    self:_finishInteraction()
    UIManager:show(SettingsDialog:new{
        canvas = self.canvas,
        on_change = function(key, value) self:_setSetting(key, value) end,
    })
end

--- Reads the stored settings onto a freshly built canvas.
function Notebook:_loadSettings()
    -- No fallback to the keys written under the old name: they are moved onto
    -- these once, when the plugin loads. See Library.migrateSettings.
    local function get(key, default)
        local value = G_reader_settings:readSetting(SETTING_PREFIX .. key)
        if value == nil then return default end
        return value
    end
    local canvas = self.canvas
    local style = get("pen_style", "fineliner")
    canvas.pen_style = (style == "fountain" or style == "pencil") and style or "fineliner"
    canvas.line_style = get("line_style", "line") == "arrow" and "arrow" or "line"
    canvas.shape_kind        = get("shape_kind", "rectangle")
    canvas.shape_fill        = get("shape_fill", false) == true
    canvas.shape_color       = get("shape_color", 0)
    canvas.pen_width         = get("pen_width", canvas.pen_width)
    local pen_color = get("pen_color", 0)
    canvas.pen_color = type(pen_color) == "number" and pen_color or 0
    canvas.highlighter_width = get("highlighter_width", canvas.highlighter_width)
    local marker_color = get("highlighter_color", canvas.highlighter_color)
    -- The former default yellow was stored before it appeared in the palette.
    canvas.highlighter_color = marker_color == 0x1FFFF66 and 0x1FDD835 or marker_color
    canvas.eraser_size       = get("eraser_size", canvas.eraser_size)
    canvas.eraser_mode       = get("eraser_mode", canvas.eraser_mode)
    local button_tool = get("barrel_button_tool", canvas.barrel_button_tool)
    canvas.barrel_button_tool = button_tool == "eraser" and "eraser" or "highlighter"
    canvas.draw_with_finger  = get("draw_with_finger", canvas.draw_with_finger)
    canvas.text_size         = get("text_size", 26)
    canvas.text_font         = get("text_font", "sans")
    canvas.text_bold         = get("text_bold", false)
    canvas.text_italic       = get("text_italic", false)
    canvas.text_underline    = get("text_underline", false)
    canvas.text_background   = get("text_background", false)
    canvas.share_format      = get("share_format", "pdf") == "xopp" and "xopp" or "pdf"
end

end
