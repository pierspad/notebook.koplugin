package.path = "./?.lua;./spec/?.lua;" .. package.path

local support = require("support")
support.installStubs()
require("uistubs").install({})
package.loaded["ffi/blitbuffer"].new = function(w, h) return support.FakeBB.new(w, h) end

local Device = require("device")
Device.screen.bb = support.FakeBB.new(400, 600)
Device.screen.refreshFast = function() end
local ui_refreshes = 0
Device.screen.refreshUI = function() ui_refreshes=ui_refreshes+1 end
local full_refreshes = 0
Device.screen.refreshFull = function(_, x, y, w, h)
    assert(x == 0 and y == 0 and w == 400 and h == 600)
    full_refreshes = full_refreshes + 1
end
Device.input = {
    TOOL_TYPE_PEN = 1, TOOL_TYPE_ERASER = 2, TOOL_TYPE_HIGHLIGHTER = 3,
}

local Zoom = require("zoom")
local Canvas = require("canvas")
local Document = require("document")
G_reader_settings={readSetting=function() end, saveSetting=function() end}
package.loaded["ui/widget/button"].setText=function(self, text) self.text=text end
package.loaded["ui/widget/button"].setIcon=function(self, icon) self.icon=icon end
local doc = Document:new("/tmp/notebook-zoom.scribe")
local canvas = Canvas:new{document=doc, content={x=0,y=0,w=400,h=600}}

Device.input.stylus_eraser_active = true
assert(canvas:resolveTool(2)=="highlighter")
canvas.barrel_button_tool="eraser"
assert(canvas:resolveTool(2)=="eraser", "pen button setting did not select eraser")
Device.input.stylus_eraser_active = false
assert(canvas:resolveTool(2)=="eraser", "rubber tip no longer erases")
canvas.barrel_down = true
assert(canvas:resolveTool(1)=="eraser", "side button ignored a pen slot")
canvas.barrel_down = false

assert(Zoom.clamp(-10,0,400,2)==0)
assert(Zoom.clamp(999,0,400,2)==200)
canvas:setZoom(2)
canvas:_zoomStylus({id=1,x=100,y=120},"pen")
canvas:_zoomStylus({id=1,x=200,y=220},"pen")
canvas:_zoomStylus({id=-1},"pen")
local stroke=doc:getPage().strokes[1]
assert(stroke and stroke:count()==2)
local x,y=stroke:getPoint(1)
assert(x==50 and y==60,"zoomed pen stored screen rather than page coordinates")
canvas:_zoomPan(-200,-300)
assert(canvas.zoom_x==100 and canvas.zoom_y==150)
assert(canvas.zoom_pan_needs_settle, "pan did not schedule cleanup")
canvas.zoom_touch_x = 12
canvas.pen_down = true
canvas:_settleZoomPan()
assert(full_refreshes == 0, "full refresh interrupted finger pan")
canvas.pen_down = false
local before_ui=ui_refreshes
canvas:_settleZoomPan()
assert(full_refreshes == 0 and ui_refreshes==before_ui+1 and not canvas.zoom_pan_needs_settle,
    "settled pan did not clean the viewport exactly once")
canvas:_zoomStylus({id=1,x=100,y=120},"pen")
canvas:_zoomStylus({id=-1},"pen")
x,y=doc:getPage().strokes[2]:getPoint(1)
assert(x==150 and y==210,"panned viewport did not map the pen to page space")
canvas:_zoomStylus({id=1,x=100,y=120},"eraser")
canvas:_zoomStylus({id=-1},"eraser")
assert(#doc:getPage().strokes==1,"zoomed eraser missed the mapped stroke")
doc:undo()
assert(#doc:getPage().strokes==2,"zoomed eraser did not make one undoable action")
canvas:_zoomStylus({id=1,x=300,y=300},"highlighter")
canvas:_zoomStylus({id=-1},"highlighter")
local highlight=doc:getPage().strokes[3]
assert(highlight.tool=="highlighter" and highlight.width==canvas.highlighter_width
    and highlight.tint==canvas.highlighter_color,
    "zoomed marker changed the stored tool, width or color")
canvas:setZoom(1)
assert(doc:getPage().strokes[1]==stroke and doc:getPage().strokes[2],
    "zoom toggle changed stored strokes")

local notebook=require("notebook"):new{document=Document:new("/tmp/notebook-zoom-button.scribe")}
notebook.canvas.content={x=0,y=0,w=400,h=600}
notebook.zoom_button.callback()
assert(notebook.canvas.zoom==2 and notebook.zoom_button.icon=="notebook.zoom-out")
notebook.zoom_button.callback()
assert(notebook.canvas.zoom==1 and notebook.zoom_button.icon=="notebook.zoom-in")

-- A real framebuffer supports getType; in that path panning must reuse the
-- rasterized page, then rebuild it when the document changes.
local cache_screen = support.FakeBB.new(40, 60)
cache_screen.getType = function() return 1 end
Device.screen.bb = cache_screen
local cached_doc = Document:new("/tmp/notebook-zoom-cache.scribe")
local cached_canvas = Canvas:new{document=cached_doc, content={x=0,y=0,w=40,h=60}}
cached_canvas:setZoom(2)
cached_canvas:_renderZoom(cache_screen)
local first_cache = cached_canvas.zoom_cache
assert(first_cache, "zoomed page was not cached")
cached_canvas:_zoomPan(-10,-10)
assert(cached_canvas.zoom_cache == first_cache, "pan rerendered the page")
local region_blits = {}
local original_blit = cache_screen.blitFrom
cache_screen.blitFrom = function(self, source, dx, dy, sx, sy, w, h)
    region_blits[#region_blits+1] = {w=w, h=h}
    return original_blit(self, source, dx, dy, sx, sy, w, h)
end
cached_canvas:_zoomStylus({id=1,x=10,y=10},"pen")
cached_canvas:_zoomStylus({id=-1},"pen")
assert(#region_blits == 0, "pen lift copied the entire zoom viewport")
cached_canvas.highlighter_width = 4
cached_canvas:_zoomStylus({id=1,x=18,y=20},"highlighter")
cached_canvas:_zoomStylus({id=-1},"highlighter")
assert(#region_blits == 1 and region_blits[1].w < 40
    and region_blits[1].h < 60,
    "marker lift did not replace only its tinted region")
local ink_cache = cached_canvas.zoom_cache
cached_canvas:_zoomStylus({id=1,x=10,y=10},"eraser")
assert(cached_canvas.zoom_cache == ink_cache and not ink_cache.freed,
    "zoomed eraser discarded the reusable enlarged cache")
cached_canvas:_zoomStylus({id=-1},"eraser")
assert(cached_canvas.zoom_cache == ink_cache, "zoomed eraser rebuilt the full cache on release")
cached_canvas:_zoomPan(-2,-2)
cached_canvas:_flushZoomPan()
assert(cached_canvas.zoom_cache, "pan did not rebuild the stale cache")
first_cache = cached_canvas.zoom_cache
cached_canvas:_zoomStylus({id=1,x=10,y=10},"pen")
cached_canvas:_zoomStylus({id=-1},"pen")
assert(cached_canvas.zoom_cache == first_cache and not first_cache.freed,
    "new ink did not update the zoom cache in place")
cached_canvas:setZoom(1)
assert(not cached_canvas.zoom_cache, "zoom cache was retained after zooming out")

local snap_doc = Document:new("/tmp/notebook-zoom-snap.scribe")
local snap_canvas = Canvas:new{document=snap_doc, content={x=0,y=0,w=400,h=600}}
snap_canvas:setZoom(2)
for px = 40, 320, 20 do
    snap_canvas:_zoomStylus({id=1,x=px,y=200},"pen")
end
snap_canvas.shape_snap:trigger()
assert(snap_canvas.zoom_stroke.shape_kind == "line", "zoomed hold did not straighten the line")
snap_canvas:_zoomStylus({id=-1},"pen")
assert(snap_doc:getPage().strokes[1].shape_kind == "line",
    "zoomed straight line was not committed")

local snap_screen = support.FakeBB.new(200, 250)
snap_screen.getType = function() return 1 end
Device.screen.bb = snap_screen
local cached_snap = Canvas:new{document=Document:new("/tmp/notebook-zoom-cached-snap.scribe"),
    content={x=0,y=0,w=200,h=250}}
cached_snap:setZoom(2)
cached_snap:_renderZoom(snap_screen)
for px = 20, 150, 10 do
    cached_snap:_zoomStylus({id=1,x=px,y=100},"pen")
end
local snap_blits = 0
local snap_blit = snap_screen.blitFrom
snap_screen.blitFrom = function(self, source, dx, dy, sx, sy, w, h)
    assert(w < 200 and h < 250, "snap copied the whole zoom viewport")
    snap_blits = snap_blits + 1
    return snap_blit(self, source, dx, dy, sx, sy, w, h)
end
cached_snap.shape_snap:trigger()
assert(snap_blits == 1 and cached_snap.zoom_stroke.shape_kind == "line",
    "zoomed snap did not replace only its dirty region")

-- Cached erase pixels, including grain and ruling, equal a fresh render after
-- several samples and a pan. Updating only dirty bounds must not leave trails.
for _,mode in ipairs({'area','stroke'}) do
    local screen=support.FakeBB.new(120,160)
    screen.getType=function() return 1 end
    Device.screen.bb=screen
    local document=Document:new('/tmp/zoom-repair.scribe')
    local c=Canvas:new{document=document,content={x=0,y=0,w=120,h=160}}
    c.eraser_mode=mode;c.eraser_size=3;c.pen_style='pencil';c.pen_width=6
    c:setZoom(2);c:_renderZoom(screen)
    for x=12,110,7 do c:_zoomStylus({id=1,x=x,y=60,pressure=2500},'pen') end
    c:_zoomStylus({id=-1},'pen')
    assert(document:getPage().strokes[1].pen_style=='pencil','zoom lost stored brush style')
    local cache=c.zoom_cache
    for x=40,60,4 do c:_zoomStylus({id=1,x=x,y=60},'eraser') end
    c:_zoomStylus({id=-1},'eraser')
    assert(c.zoom_cache==cache,'erase rebuilt entire cache')
    local expected=support.FakeBB.new(120,160)
    c:_renderZoom(expected,true)
    for y=0,159 do for x=0,119 do
        assert(screen:get(x,y)==expected:get(x,y),mode..' erase left stale pixels')
    end end
    c:_zoomPan(-20,-20);c:_flushZoomPan();c:_renderZoom(expected,true)
    for y=0,159 do for x=0,119 do
        assert(screen:get(x,y)==expected:get(x,y),mode..' pan exposed stale cache pixels')
    end end
end
-- A final erase sample inside the refresh interval still paints while the
-- nib pauses in contact: release is not required to reveal its result.
local clock=0
local timing=require('ui/time');timing.now=function() return clock end;timing.to_ms=function(t) return t end
local UI=require('ui/uimanager');local scheduled={}
UI.scheduleIn=function(_,delay,fn) scheduled[fn]=delay end
UI.unschedule=function(_,fn) scheduled[fn]=nil end
local erdoc=Document:new('/tmp/zoom-trailing.scribe')
local ercanvas=Canvas:new{document=erdoc,content={x=0,y=0,w=120,h=160}}
ercanvas.eraser_mode='stroke';ercanvas.eraser_size=2
local Stroke=require('stroke')
for _,x in ipairs({10,30}) do local s=Stroke:new{};s:addPoint(x,30);erdoc:addStroke(s) end
ercanvas:setZoom(2)
ercanvas:_zoomStylus({id=1,x=20,y=60},'eraser')
clock=1;ercanvas:_zoomStylus({id=1,x=60,y=60},'eraser')
assert(scheduled[ercanvas.zoom_erase_cb] and ercanvas.zoom_erase_region,'erase has no trailing refresh')
clock=100;ercanvas.zoom_erase_cb()
assert(not ercanvas.zoom_erase_region and not scheduled[ercanvas.zoom_erase_cb], 'trailing erase was not flushed')
ercanvas:_zoomStylus({id=-1},'eraser')
-- Zoom must read the physical sensor when virtual stylus events omit pressure.
local c=Canvas:new{document=Document:new('/tmp/zoom-pressure.scribe'),content={x=0,y=0,w=120,h=160}}
c.pen_style='fountain';c.pressure_sensor={read=function() return 1024 end};c:setZoom(2)
c:_zoomStylus({id=1,x=40,y=50},'pen')
local _,_,p=c.zoom_stroke:getPoint(1)
assert(p>0.24 and p<0.26 and c.zoom_stroke.pen_style=='fountain','zoom ignored sensor pressure')

print("zoom viewport mapping and pen storage passed")
