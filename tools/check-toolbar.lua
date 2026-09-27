-- Run in KOReader; optional third argument is the previous notebook.lua.
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/tmp/toolbar-settings.lua')
local Device=require('device');require('document/canvascontext'):init(Device)
local dir,out=assert(arg[1]),assert(arg[2])
local load=dofile(dir..'/loader.lua')(dir)
local Icon=require('ui/widget/iconwidget');local init=Icon.init
Icon.init=function(self)
    if self.icon and self.icon:match('^notebook%.') then self.file=dir..'/icons/'..self.icon..'.svg' end
    return init(self)
end
local Screen=Device.screen
local function positions(Notebook)
    local doc=load('document'):new('/tmp/toolbar.scribe')
    local nb=Notebook:new{document=doc}
    local paint=nb.clock_text.paintTo
    nb.clock_text.paintTo=function(self,bb,x,y)
        local size=self:getSize();self.dimen={x=x,y=y,w=size.w,h=size.h}
        return paint(self,bb,x,y)
    end
    nb:paintTo(Screen.bb,0,0)
    local result={}
    for _,name in ipairs({'undo_button','redo_button','prev_page_button','next_page_button',
        'page_button','paste_button','zoom_button','clock_text'}) do
        local d=nb[name].dimen;result[name]={x=d.x,y=d.y,w=d.w,h=d.h}
    end
    for i,b in ipairs(nb.tool_buttons) do result['tool'..i]={x=b.dimen.x,w=b.dimen.w} end
    return result,nb
end
local old
if arg[3] then
    local chunk=assert(loadfile(arg[3]));setfenv(chunk,setmetatable({require=load},{__index=_G}))
    old=positions(chunk())
end
local new,nb=positions(load('notebook'))
assert(nb.clock_inset.width>0,'clock has no inset')
if old then
    for name,d in pairs(new) do
        if name=='clock_text' then
            assert(d.x==old[name].x+nb.clock_inset.width,'clock did not move by its inset')
        else
            assert(d.x==old[name].x and d.w==old[name].w,'button moved: '..name)
        end
    end
end
Screen.bb:writePNG(out..'/toolbar-'..Screen:getWidth()..'.png')
print('toolbar '..Screen:getWidth()..': clock inset '..nb.clock_inset.width..'px; all compared buttons unchanged')
