-- Binary feedback while the nib moves, authoritative color after the stroke.
-- Snapshot only tiles touched by this contact, before preview pixels are drawn.
-- Neither the snapshots nor the preview descriptor enters the document.
local Device = require("device")
local Rect = require("rect")
local LiveInk = {}
local Screen = Device.screen
local TILE_SIZE = 128

function LiveInk:_beginLiveInk(stroke)
    local color = stroke.color or 0
    if stroke.tool ~= "highlighter" and (stroke.tool ~= "pen"
        or color == 0 or color == 255 or color == 0x1FFFFFF) then return end
    local base = {tiles={}, seen={}}
    function base:free()
        for _, tile in ipairs(self.tiles) do tile.bb:free() end
        self.tiles, self.seen, self.freed = {}, {}, true
    end
    self.live_ink = {base=base, brush={tool=stroke.tool,
        pen_style=stroke.pen_style, width=stroke.width, color=0, live_preview=true}}
end

-- Call before rendering a segment; a previously captured tile must retain its
-- pre-contact pixels even when the stroke doubles back over earlier preview.
function LiveInk:_captureLiveInk(x0,y0,x1,y1,width)
    local live = self.live_ink
    if not live then return end
    local pad = math.ceil(width/2)+2
    local x,y,w,h = Rect.clamp(math.min(x0,x1)-pad,math.min(y0,y1)-pad,
        math.abs(x1-x0)+pad*2,math.abs(y1-y0)+pad*2,self.content)
    if not x then return end
    local c, base = self.content, live.base
    local columns = math.ceil(c.w/TILE_SIZE)
    for row=math.floor((y-c.y)/TILE_SIZE),math.floor((y+h-1-c.y)/TILE_SIZE) do
        for column=math.floor((x-c.x)/TILE_SIZE),math.floor((x+w-1-c.x)/TILE_SIZE) do
            local key = row*columns+column
            if not base.seen[key] then
                local tx,ty = c.x+column*TILE_SIZE,c.y+row*TILE_SIZE
                local tw,th = math.min(TILE_SIZE,c.x+c.w-tx),math.min(TILE_SIZE,c.y+c.h-ty)
                local tile = {x=tx,y=ty,w=tw,h=th,bb=Screen.bb:viewport(tx,ty,tw,th):copy()}
                base.tiles[#base.tiles+1] = tile
                base.seen[key] = tile
            end
        end
    end
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
        if x then
            for _,tile in ipairs(live.base.tiles) do
                local tx,ty,tw,th = Rect.clamp(x,y,w,h,tile)
                if tx then Screen.bb:blitFrom(tile.bb,tx,ty,tx-tile.x,ty-tile.y,tw,th) end
            end
        end
    end
    live.base:free()
    return b
end

function LiveInk:_finishLiveInk(stroke)
    local box = self:_restoreLiveInk()
    if not box then return false end
    self:_drawViewStroke(stroke)
    self:_scheduleReconcile(box.x,box.y,box.w,box.h,true)
    return true
end

return LiveInk
