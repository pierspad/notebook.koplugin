-- Keyboard dialog presentation; notebooktext.lua owns editing and commit/cancel.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local InputDialog = require("ui/widget/inputdialog")
local InputText = require("ui/widget/inputtext")
local Size = require("ui/size")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen

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
local CanvasTextDialog = InputDialog:extend{inputtext_class=CanvasTextInput}
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

return CanvasTextDialog
