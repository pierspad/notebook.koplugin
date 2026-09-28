-- Native widget stack and pixel proof: a clock tick cannot overwrite a cover.
-- SDL_VIDEODRIVER=dummy ./luajit /path/check-suspend.lua /path/plugin/lua
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/dev/null')
local Device=require('device');require('document/canvascontext'):init(Device)
local directory=assert(arg[1],'plugin Lua directory required')
local load=dofile(directory..'/loader.lua')(directory)
local Icon=require('ui/widget/iconwidget');local init=Icon.init
Icon.init=function(self)
    if self.icon and self.icon:match('^notebook%.') then self.file=directory..'/icons/'..self.icon..'.svg' end
    return init(self)
end
local UI=require('ui/uimanager');local Event=require('ui/event')
local Screen=Device.screen;local BB=require('ffi/blitbuffer')
for _,mode in ipairs({'Fast','UI','Full'}) do Screen['refresh'..mode]=function() end end
local Document=load('document');local Notebook=load('notebook')
local ScreenSaverWidget=require('ui/widget/screensaverwidget')
local Widget=require('ui/widget/widget')
local Geom=require('ui/geometry')
local nb=Notebook:new{document=Document:new(nil)}
nb.document.save=function(self) self.dirty=false;return true end
UI:show(nb);UI:forceRePaint()
local c=nb.canvas
for _,zoom in ipairs({1,2}) do
    if c.zoom~=zoom then c:setZoom(zoom) end
    UI:forceRePaint()
    c:onStylusEvent({id=1,x=200,y=c.content.y+150,tool=Device.input.TOOL_TYPE_PEN})
    local active=zoom==2 and c.zoom_stroke or c.stroke
    assert(active,'native input did not start stroke')
    local count=#nb.document:getPage().strokes
    -- The real screensaver covers the widget stack. Give it a uniform cover
    -- so any toolbar line, glyph or ink write is detectable pixel by pixel.
    Device.screen_saver_mode=true
    local cover=ScreenSaverWidget:new{background=BB.Color8(155),covers_fullscreen=true,
        widget=Widget:new{dimen=Geom:new{x=0,y=0,w=Screen:getWidth(),h=Screen:getHeight()}}}
    UI:show(cover);UI:forceRePaint()
    nb.clock_tick() -- critical gap before the Suspend event
    for y=0,math.ceil(nb.toolbar.dimen.h)-1 do for x=0,Screen:getWidth()-1 do
        assert(Screen.bb:getPixel(x,y):getColor8().a==155,'clock overwrote cover before suspend')
    end end
    UI:broadcastEvent(Event:new('Suspend'))
    for _,name in ipairs(c.lifecycle_callbacks) do c[name]() end
    nb.clock_tick();nb:_refreshToolbar()
    local expected=155
    for y=0,Screen:getHeight()-1 do for x=0,Screen:getWidth()-1 do
        assert(Screen.bb:getPixel(x,y):getColor8().a==expected,'Notebook wrote on screensaver pixels')
    end end
    UI:broadcastEvent(Event:new('Resume'))
    assert(nb.suspended and c.suspended,'Resume dismissed a still-visible cover')
    UI:close(cover) -- real CloseWidget broadcasts OutOfScreenSaver before cleanup
    nb.resume_cb()
    assert(not nb.suspended and not c.suspended,'native cover close failed to resume')
    assert(#nb.document:getPage().strokes==count+1,'native suspend lost/doubled active ink')
    UI:forceRePaint();nb.clock_tick()
    assert(not load('safe').failed,'native suspension triggered recovery')
end
UI:close(nb)
assert(not Device.input.stylus_callback,'closed native notebook retained its stylus callback')
print('native suspend: real screensaver/widget events preserve every cover pixel and unfinished ink at 1x/2x')
