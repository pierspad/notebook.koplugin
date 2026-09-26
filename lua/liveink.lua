-- Binary feedback while the nib moves, authoritative color after the stroke.
-- A single framebuffer snapshot avoids replaying the whole page to remove the
-- preview. Neither the snapshot nor the preview descriptor enters the document.
local Device = require("device")
local Rect = require("rect")
local LiveInk = {}
local Screen = Device.screen

function LiveInk:_beginLiveInk(stroke)
    local color = stroke.color or 0
    if stroke.tool ~= "highlighter" and (stroke.tool ~= "pen"
        or color == 0 or color == 255 or color == 0x1FFFFFF) then return end
    self.live_ink = {base=Screen.bb:copy(), brush={tool=stroke.tool,
        pen_style=stroke.pen_style, width=stroke.width, color=0, live_preview=true}}
end

function LiveInk:_liveBrush(stroke)
    return self.live_ink and self.live_ink.brush or stroke
end

function LiveInk:_trackLiveInk(x, y, w, h)
    local live = self.live_ink
    if live and x then live.dirty = Rect.grow(live.dirty, x, y, w, h) end
end

-- Also used before shape recognition replaces the raw stroke. Only restore
-- pixels touched by the preview; the toolbar and other overlays stay intact.
function LiveInk:_restoreLiveInk()
    local live = self.live_ink
    if not live then return end
    self.live_ink = nil
    local b = live.dirty
    if b then
        local x,y,w,h = Rect.clamp(b.x,b.y,b.w,b.h,self.content)
        if x then Screen.bb:blitFrom(live.base,x,y,x,y,w,h) end
    end
    live.base:free()
    return b
end

function LiveInk:_finishLiveInk(stroke)
    local box = self:_restoreLiveInk()
    if not box then return false end
    self:_drawViewStroke(stroke)
    self:_scheduleReconcile(box.x,box.y,box.w,box.h)
    return true
end

return LiveInk
