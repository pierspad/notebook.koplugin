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
    if self.button_table then
        for _, row in ipairs(self.button_table.buttons_layout or {}) do
            for _, button in ipairs(row) do
                if button.frame then
                    -- Controls need a stable surface over arbitrary PDF
                    -- artwork. Keep each key white and outlined, while the
                    -- dialog and text preview themselves remain transparent.
                    button.frame.background = Blitbuffer.COLOR_WHITE
                    button.frame.bordersize = Size.border.thin
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
    local dialog
    self.canvas.hidden_stroke = original

    local function redraw(value)
        local dirty = nil
        if preview then dirty=require("rect").grow(dirty, preview:getBounds()) end
        if original then dirty=require("rect").grow(dirty, original:getBounds()) end
        -- The page is the editor preview. Mirror the real Unicode cursor from
        -- the hidden input widget so arrow-key edits remain understandable.
        local shown=value
        local input=dialog and dialog._input_widget
        if input and input.charlist and input.charpos then
            local before,after={},{}
            for i=1,input.charpos-1 do before[#before+1]=input.charlist[i] end
            for i=input.charpos,#input.charlist do after[#after+1]=input.charlist[i] end
            shown=table.concat(before).."│"..table.concat(after)
        elseif shown=="" then
            shown="│"
        end
        -- Show the chosen background immediately, including transparent text
        -- over ruling, so the toolbar choice matches the committed result.
        local preview_style={}
        for key,value in pairs(style) do preview_style[key]=value end
        preview_style.text_background=style.text_background
        preview=require("textobject").create(shown,x,y,width,size,preview_style)
        dirty=require("rect").grow(dirty,preview:getBounds())
        self.canvas.text_preview=preview
        self.canvas:_repaintRegion(dirty.x,dirty.y,dirty.w,dirty.h,true)
        self.canvas:_refreshNow(dirty.x,dirty.y,dirty.w,dirty.h,"ui")
    end

    local function currentText() return dialog and dialog:getInputText() or (original and original.text or "") end
    local function restyle(fn) fn(); redraw(currentText()) end
    local families={"sans","serif","mono"}
    local function cancel()
        UIManager:close(dialog)
        local dirty = nil
        if preview then dirty=require("rect").grow(dirty,preview:getBounds()) end
        if original then dirty=require("rect").grow(dirty,original:getBounds()) end
        self.canvas.hidden_stroke=nil; self.canvas.text_preview=nil
        if dirty then self.canvas:_repaintRegion(dirty.x,dirty.y,dirty.w,dirty.h) end
    end
    local function commit()
        local value = dialog:getInputText()
        UIManager:close(dialog)
        self.canvas.hidden_stroke=nil; self.canvas.text_preview=nil
        if not value or value == "" then
            if preview then self.canvas:_repaintRegion(preview:getBounds()) end
            return
        end
        local stroke = require("textobject").create(value,x,y,width,size,style)
        if original then self.document:replaceStroke(original,stroke) else self.document:addStroke(stroke) end
        self.canvas:_repaintRegion(stroke:getBounds())
        self.canvas:_showLassoMenu({stroke})
        self:_onDocumentChanged()
    end
    dialog = CanvasTextDialog:new{
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
                {text="Aa", text_font_bold=false, callback=function() restyle(function()
                    local at=1; for i,v in ipairs(families) do if v==style.font_family then at=i end end
                    style.font_family=families[at%#families+1]
                end) end},
                {text="B", text_font_bold=true,
                    checked_func=function() return style.text_bold end,
                    callback=function() restyle(function() style.text_bold=not style.text_bold end) end},
                {text="I", text_font_face="NotoSans-Italic.ttf", text_font_bold=false,
                    checked_func=function() return style.text_italic end,
                    callback=function() restyle(function() style.text_italic=not style.text_italic end) end},
                {text="U̲", text_font_bold=false,
                    checked_func=function() return style.text_underline end,
                    callback=function() restyle(function() style.text_underline=not style.text_underline end) end},
            },
            {
                {text=_("White"), checked_func=function() return style.text_background end,
                    callback=function() restyle(function() style.text_background=true end) end},
                {text=_("Transparent"), checked_func=function() return not style.text_background end,
                    callback=function() restyle(function() style.text_background=false end) end},
                {text="A−", callback=function() restyle(function() size=math.max(10,size-2) end) end},
                {text="A+", callback=function() restyle(function() size=math.min(96,size+2) end) end},
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
