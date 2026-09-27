-- On-page text editing, formatting controls and preview lifecycle.
local Blitbuffer = require("ffi/blitbuffer")
local Size = require("ui/size")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local _ = require("i18n")
local Screen = Device.screen
local NotebookText = {}
local CanvasTextDialog = require("textdialog")

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
        end
        if original then dirty=require("rect").grow(dirty, original:getBounds()) end
        -- The page is the editor preview. Mirror the real Unicode cursor from
        -- the hidden input widget so arrow-key edits remain understandable.
        local input=dialog and dialog._input_widget
        -- Show the chosen background immediately, including transparent text
        -- over ruling, so the toolbar choice matches the committed result.
        local unchanged = preview and preview.text == value and preview.font_size == size
            and preview.font_family == style.font_family and preview.text_bold == style.text_bold
            and preview.text_italic == style.text_italic
        local cursor = input and input.charpos or 1
        local caret_only = unchanged and preview.text_underline == style.text_underline
            and preview.text_background == style.text_background
        local old_caret
        if caret_only then
            if preview.cursor_pos == cursor then return end
            local cx,cy,cw,ch=require("textobject").caretBounds(preview)
            if cx then old_caret=require("rect").grow(nil,cx,cy,cw,ch) end
        end
        if not unchanged then
            require("textobject").freeCache(preview)
            preview=require("textobject").create(value,x,y,width,size,style)
        end
        preview.text_underline = style.text_underline
        preview.text_background = style.text_background
        preview.cursor_pos = cursor
        dirty=require("rect").grow(dirty,preview:getBounds())
        if old_caret then
            local cx,cy,cw,ch=require("textobject").caretBounds(preview)
            if cx then dirty=require("rect").grow(old_caret,cx,cy,cw,ch) end
        end
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
