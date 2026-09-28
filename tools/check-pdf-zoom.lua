-- Native PDF zoom: pass plugin Lua directory and a PDF fixture path.
-- SDL_VIDEODRIVER=dummy ./luajit /path/check-pdf-zoom.lua /path/plugin/lua /path/fixture.pdf
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/dev/null')
local Device=require('device')
require('document/canvascontext'):init(Device)
local directory=assert(arg[1],'plugin Lua directory required')
local load=dofile(directory..'/loader.lua')(directory)
local Icon=require('ui/widget/iconwidget');local init=Icon.init
Icon.init=function(self)
    if self.icon and self.icon:match('^notebook%.') then self.file=directory..'/icons/'..self.icon..'.svg' end
    return init(self)
end
local BB=require('ffi/blitbuffer')
local UI=require('ui/uimanager')
local Event=require('ui/event')
local Screen=Device.screen
local full,fast=0,0
Screen.refreshFast=function() fast=fast+1 end
Screen.refreshUI=function() end
Screen.refreshFull=function(_,x,y,w,h)
    assert(x>=0 and y>=0 and w>0 and h>0);full=full+1
end
local Document=load('document')
local PDF=load('pdfbackground')
local Canvas=load('canvas');local Stroke=load('stroke')
local fixture=assert(arg[2],'PDF fixture path required')
local count=PDF.count(fixture)
local mupdf=require('ffi/mupdf');local open=mupdf.openDocument;local opens=0
mupdf.openDocument=function(...) opens=opens+1;return open(...) end
local comparisons=0
for _,kind in ipairs({BB.TYPE_BB8,BB.TYPE_BBRGB32}) do
    for rotation=0,3 do
        for page=1,math.min(count,2) do
            PDF.clear()
            local actual=BB.new(260,320,kind);actual:setRotation(rotation)
            local expected=BB.new(260,320,kind);expected:setRotation(rotation)
            local w,h=actual:getWidth(),actual:getHeight()
            local doc=Document:new(nil)
            doc:getPage().background={file=fixture,page=page}
            local c=Canvas:new{document=doc,content={x=7,y=25,w=w-14,h=h-35}}
            c.zoom=2;c.zoom_x=7;c.zoom_y=25
            local stroke=Stroke:new{width=5,pen_style='fineliner'}
            for x=15,w-20,17 do stroke:addPoint(x,45+x/3,0.7) end
            doc:addStroke(stroke)
            local before=opens
            for _,offset in ipairs({0,0.5,13.5,c.content.w/2}) do
                c.zoom_x=7+offset;c.zoom_y=25+math.min(offset,c.content.h/2)
                actual:fill(BB.COLOR_WHITE);expected:fill(BB.COLOR_WHITE)
                c:_renderZoom(actual);c:_renderZoom(expected,true)
                for y=0,h-1 do for x=0,w-1 do
                    assert(actual:getPixel(x,y)==expected:getPixel(x,y),
                        string.format('PDF mismatch page=%d rotation=%d at %d,%d',page,rotation,x,y))
                end end
                comparisons=comparisons+1
            end
            assert(opens==before+1,'PDF pan rerasterized the background')
            -- Dirty eraser repair restores immutable PDF pixels in the cache.
            local screenbb=Screen.bb;Screen.bb=actual
            c.zoom_x=7;c.zoom_y=25;c:_renderZoom(actual)
            doc:getPage().strokes={}
            c.zoom_erase_region={x=0,y=0,w=w,h=h}
            c:_flushZoomErase()
            expected:fill(BB.COLOR_WHITE);c:_renderZoom(expected,true)
            for y=25,h-10 do for x=7,w-8 do
                assert(actual:getPixel(x,y)==expected:getPixel(x,y),'PDF eraser restoration mismatch')
            end end
            assert(opens==before+1,'PDF eraser rerasterized background')
            Screen.bb=screenbb
            c:_clearZoomCache();actual:free();expected:free()
        end
    end
end
PDF.clear();mupdf.openDocument=open
print(string.format('PDF zoom: %d native viewport comparisons, rotations, edges and eraser repairs passed',comparisons))
