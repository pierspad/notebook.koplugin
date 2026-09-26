-- On-page text editing, formatting controls and preview lifecycle.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local InputDialog = require("ui/widget/inputdialog")
local InputText = require("ui/widget/inputtext")
local Size = require("ui/size")
local VerticalSpan = require("ui/widget/verticalspan")
local UIManager = require("ui/uimanager")
local _ = require("i18n")
local Screen = Device.screen
local NotebookText = {}

-- InputDialog still owns keyboard input and cursor movement, but its ordinary
-- textbox would duplicate the live text already painted on the page. Keep the
-- editor functional while making that redundant copy invisible.
local CanvasTextInput = InputText:extend{
    skip_paint = true,
    bordersize = 0,
    padding = 0,
    margin = 0,
}

-- The page itself is the text editor. Keep InputDialog's keyboard/focus logic
-- and formatting buttons, but remove its title and opaque full-width panel.
local CanvasTextDialog = InputDialog:extend{}
function CanvasTextDialog:init()
    -- IconWidget and TextWidget have different natural heights. Give every
    -- label the same content box before ButtonTable measures its rows.
    for _, row in ipairs(self.buttons or {}) do
        for _, button in ipairs(row) do button.height = Screen:scaleBySize(28) end
    end
    InputDialog.init(self)
    if self.dialog_frame then
        self.dialog_frame.background = nil
        self.dialog_frame.bordersize = 0
    end
    if self.vgroup then
        self.vgroup[1] = VerticalSpan:new{ width = 0 }
        self.vgroup:resetLayout()
    end
    -- ButtonTable normally paints one white slab (plus separators) across the
    -- page. Make only its button frames transparent and disable its LineWidget
    -- separators. Clearing every `background` recursively is unsafe: a
    -- LineWidget still calls paintRect and a nil colour crashes on the device.
    if self.button_table and self.button_table.container then
        local rows = {}
        for _, child in ipairs(self.button_table.container) do
            if type(child) == "table" and child[1] and (child[1].callback or child[1].frame) then
                table.insert(rows, child)
            end
        end
        if #rows > 1 then
            for i = #self.button_table.container, 1, -1 do
                self.button_table.container[i] = nil
            end
            for i, row in ipairs(rows) do
                self.button_table.container[i] = row
            end
            self.button_table.container:resetLayout()
        end
        for _, row in ipairs(self.button_table.buttons_layout or {}) do
            for _, button in ipairs(row) do
                button.bordersize = 0
                if button.frame then
                    -- Controls need a stable surface over arbitrary PDF
                    -- artwork. Keep each key white and outlined, while the
                    -- dialog and text preview themselves remain transparent.
                    button.frame.background = Blitbuffer.COLOR_WHITE
                    button.frame.inner_bordersize = Size.border.thin
                end
            end
        end
        local function hideSeparators(widget)
            if type(widget) ~= "table" then return end
            if widget.style == "solid" and widget.dimen and not widget.frame then
                widget.style = "none"
            end
            for _, child in ipairs(widget) do hideSeparators(child) end
        end
        hideSeparators(self.button_table.container)
    end
end

function CanvasTextDialog:onCloseWidget()
    if self.editor_cleanup then self.editor_cleanup() end
    if InputDialog.onCloseWidget then return InputDialog.onCloseWidget(self) end
end

function NotebookText:_insertText(x, y)
    self:_editText(nil, x, y)
end

function NotebookText:_editText(original, x, y)
    x, y = x or original.x_min, y or original.y_min
    local function textOption(key, fallback)
        if original and original[key] ~= nil then return original[key] end
        local value=self.canvas[key]
        return value ~= nil and value or fallback
    end
    local style = {
        font_family = original and original.font_family or self.canvas.text_font or "sans",
        text_bold = textOption("text_bold",false),
        text_italic = textOption("text_italic",false),
        text_underline = textOption("text_underline",false),
        text_background = textOption("text_background",false),
    }
    local size = original and original.font_size or self.canvas.text_size
    local width = original and (original.x_max-original.x_min)
        or math.max(80, math.min(Screen:scaleBySize(600), self.canvas.content.x+self.canvas.content.w-x))
    local preview
    local closed=false
    local dialog
    self.canvas.hidden_stroke = original
    local preview_renderer = require("textpreview").new(self.canvas, original)

    local function updateBgButton()
        if not (dialog and dialog.button_table) then return end
        local btn = dialog.button_table.button_by_id and dialog.button_table.button_by_id["bg_toggle"]
        if btn then
            local icon_name = style.text_background and "notebook.bg-white" or "notebook.bg-none"
            if btn.setIcon then
                btn:setIcon(icon_name, btn.width)
                btn.bordersize = 0
                if btn.frame then
                    btn.frame.background = Blitbuffer.COLOR_WHITE
                    btn.frame.inner_bordersize = Size.border.thin
                end
            else
                btn.icon = icon_name
            end
            UIManager:setDirty(dialog, "ui")
        end
    end

    local function updateSizeButton()
        if not (dialog and dialog.button_table) then return end
        local btn = dialog.button_table.button_by_id and dialog.button_table.button_by_id["size_display"]
        if btn then
            local txt = size .. "pt"
            if btn.setText then
                btn:setText(txt, btn.width)
                btn.bordersize = 0
                if btn.frame then
                    btn.frame.background = Blitbuffer.COLOR_WHITE
                    btn.frame.inner_bordersize = Size.border.thin
                end
            else
                btn.text = txt
            end
            UIManager:setDirty(dialog, "ui")
        end
    end

    local function redraw(value)
        if closed then return end
        local dirty = nil
        if preview then
            dirty=require("rect").grow(dirty, preview:getBounds())
            require("textobject").freeCache(preview)
        end
        if original then dirty=require("rect").grow(dirty, original:getBounds()) end
        -- The page is the editor preview. Mirror the real Unicode cursor from
        -- the hidden input widget so arrow-key edits remain understandable.
        local input=dialog and dialog._input_widget
        -- Show the chosen background immediately, including transparent text
        -- over ruling, so the toolbar choice matches the committed result.
        local preview_style={}
        for key,val in pairs(style) do preview_style[key]=val end
        preview_style.text_background=style.text_background
        preview=require("textobject").create(value,x,y,width,size,preview_style)
        preview.cursor_pos = input and input.charpos or 1
        dirty=require("rect").grow(dirty,preview:getBounds())
        self.canvas.text_preview=preview
        preview_renderer:paint(preview, dirty)

    end

    local function currentText() return dialog and dialog:getInputText() or (original and original.text or "") end
    local function restyle(fn) fn(); redraw(currentText()) end
    local families={"sans","serif","mono"}
    local function cleanup()
        if closed then return end
        closed=true
        preview_renderer:free()
        local dirty = nil
        if preview then
            dirty=require("rect").grow(dirty,preview:getBounds())
            require("textobject").freeCache(preview)
        end
        if original then dirty=require("rect").grow(dirty,original:getBounds()) end
        self.canvas.hidden_stroke=nil; self.canvas.text_preview=nil
        if dirty then self.canvas:_repaintRegion(dirty.x,dirty.y,dirty.w,dirty.h) end
    end
    local function cancel()
        cleanup()
        UIManager:close(dialog)
    end
    local function commit()
        closed=true
        local value = dialog:getInputText()
        local Text = require("textobject")
        local Rect = require("rect")
        local dirty = preview and Rect.grow(nil, preview:getBounds()) or nil
        if original then dirty=Rect.grow(dirty, original:getBounds()) end
        preview_renderer:free()
        UIManager:close(dialog)
        Text.freeCache(preview)
        self.canvas.hidden_stroke=nil; self.canvas.text_preview=nil
        local stroke
        if Text.hasContent(value) then
            stroke=Text.create(value,x,y,width,size,style)
            if original then self.document:replaceStroke(original,stroke) else self.document:addStroke(stroke) end
            dirty=Rect.grow(dirty,stroke:getBounds())
        elseif original then
            self.document:removeStrokes({original})
        end
        Text.freeCache(original)
        if dirty then self.canvas:_repaintRegion(dirty.x,dirty.y,dirty.w,dirty.h) end
        if stroke then self.canvas:_showLassoMenu({stroke}) end
        if stroke or original then self:_onDocumentChanged() end
    end
    dialog = CanvasTextDialog:new{
        editor_cleanup=cleanup,
        -- Kept for accessibility/introspection; CanvasTextDialog removes the
        -- visible title bar so it does not cover the page.
        title = original and _("Edit text") or _("Insert text"),
        input = original and original.text or "", allow_newline=true,
        inputtext_class=CanvasTextInput,
        condensed=true, text_height=1, input_padding=0, input_margin=0,
        width=math.min(self.canvas.content.w, math.max(Screen:scaleBySize(320),
            math.min(width, Screen:scaleBySize(480)))), button_padding=0,
        input_face=Font:getFace("cfont",size),
        strike_callback=function()
            if dialog then redraw(dialog:getInputText()) end
        end,
        buttons = {
            {
                {text="✕", callback=cancel},
                {text="Aa", font_bold=false, callback=function() restyle(function()
                    local at=1; for i,v in ipairs(families) do if v==style.font_family then at=i end end
                    style.font_family=families[at%#families+1]
                end) end},
                {text="B", font_bold=true,
                    checked_func=function() return style.text_bold end,
                    callback=function() restyle(function() style.text_bold=not style.text_bold end) end},
                {text="I", font_face="NotoSans-Italic.ttf", font_bold=false,
                    checked_func=function() return style.text_italic end,
                    callback=function() restyle(function() style.text_italic=not style.text_italic end) end},
                {text="U̲", font_bold=false,
                    checked_func=function() return style.text_underline end,
                    callback=function() restyle(function() style.text_underline=not style.text_underline end) end},
            },
            {
                {
                    id = "bg_toggle",
                    icon = style.text_background and "notebook.bg-white" or "notebook.bg-none",
                    icon_width = Screen:scaleBySize(22),
                    icon_height = Screen:scaleBySize(22),
                    callback = function()
                        restyle(function()
                            style.text_background = not style.text_background
                            updateBgButton()
                        end)
                    end,
                },
                {text="A−", callback=function() restyle(function() size=math.max(10,size-2); updateSizeButton() end) end},
                {id="size_display", text=size .. "pt", font_bold=false,
                    callback=function() restyle(function() size=24; updateSizeButton() end) end},
                {text="A+", callback=function() restyle(function() size=math.min(96,size+2); updateSizeButton() end) end},
                {text="✓", is_enter_default=true, callback=commit},
            },
        },
    }
    redraw(original and original.text or "")
    if dialog.movable then
        dialog.movable.anchor=function()
            local px,py,pw,ph=preview:getBounds()
            return Geom:new{x=px,y=py,w=pw,h=ph}
        end
    end
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return NotebookText
