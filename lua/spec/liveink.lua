package.path='./?.lua;./spec/?.lua;'..package.path
local support=require('support');support.installStubs()
require('uistubs').install({})
local Screen=require('device').screen
local Canvas,Document,Stroke=require('canvas'),require('document'),require('stroke')
require('ffi/blitbuffer').new=function(w,h) return support.FakeBB.new(w,h) end
G_reader_settings={readSetting=function() end,saveSetting=function() end}
local fast,ui=0,0
Screen.refreshFast=function() fast=fast+1 end
Screen.refreshUI=function() ui=ui+1 end
Screen.refreshFull=function() error('live ink requested full refresh') end
local now=0;require('ui/time').now=function() now=now+25;return now end
require('ui/time').to_ms=function(t) return t end
for _,zoom in ipairs({1,2}) do
 for _,brush in ipairs({{'pen','fineliner',90},{'pen','pencil',85},{'pen','fountain',120},
     {'highlighter',nil,0},{'highlighter',nil,0,true},{'pen','fountain',120,true},{'pen','fineliner',255},{'pen','fineliner',0}}) do
    Screen.bb=support.FakeBB.new(160,200)
    local doc=Document:new('/tmp/liveink.scribe');doc:setTemplate('blank')
    local c=Canvas:new{document=doc,content={x=0,y=10,w=160,h=190}}
    c.dimen={x=0,y=0,w=160,h=200}
    c.pen_style,c.pen_color=brush[2],brush[3];c.highlighter_color=160
    c.pen_width=6;c.highlighter_width=14
    local under=Stroke:new{tool='pen',width=2,color=0}
    under:addPoint(0,80,1);under:addPoint(155,80,1);doc:addStroke(under)
    c:setZoom(zoom)
    if zoom==2 then c.zoom_x=13;c.zoom_y=24 end
    c:paintTo(Screen.bb,0,0)
    local before_ui=ui
    if zoom==1 then c:_beginStroke(brush[1],20,65,1)
    else c:_zoomStylus({id=1,x=20,y=65,pressure=4095},brush[1]) end
    local snapshot=c.live_ink and c.live_ink.base
    if zoom==1 then c:_extendStroke(60,80,1) else c:_zoomStylus({id=1,x=60,y=80,pressure=4095},brush[1]) end
    if zoom==1 then c:_extendStroke(110,90,1)
    else c:_zoomStylus({id=1,x=110,y=90,pressure=4095},brush[1]) end
    assert(ui==before_ui,'gray waveform during contact')
    if brush[4] then
        local raw=c.stroke or c.zoom_stroke
        local clean=assert(require('shape').recognize(raw,'arrow'),'test path not recognized')
        c:_applyShapeSnap(clean,raw)
        assert(not c.live_ink and snapshot.freed,'snap kept its binary preview')
        before_ui=ui
        -- Snap/arrow deliberately requests a full idle cleanup.
        c.reconcile_full=nil
    end
    if zoom==1 then c:_endStroke() else c:_zoomStylus({id=-1},brush[1]) end
    assert(not c.live_ink and (not snapshot or snapshot.freed),'snapshot leaked')
    assert(ui==before_ui,'gray waveform on every lift')
    assert(#doc:getPage().strokes==2,'stroke lost or duplicated')
    local saved=doc:getPage().strokes[2]
    assert(not saved.live_preview and saved.pen_style==brush[2],'preview corrupted metadata')
    -- Compare the incrementally restored screen to an independent full render.
    local actual=Screen.bb:copy()
    c:paintTo(Screen.bb,0,0)
    for y=10,199 do for x=0,159 do
        assert(actual:get(x,y)==Screen.bb:get(x,y),
            string.format('preview residue at %d,%d zoom=%d %s/%s',x,y,zoom,brush[1],tostring(brush[2])))
    end end
    c.pen_down=false;c:_runReconcile()
    assert(ui==before_ui+1,'idle color reconciliation missing')
    c:_clearZoomCache()
 end
end
assert(fast>0,'binary preview never refreshed')
print('live ink: exact final pixels, preserved brushes, deferred color and freed snapshots at 1x/2x')
