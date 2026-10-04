package.path='./?.lua;./spec/?.lua;'..package.path
local support=require('support');local store=support.installStubs()
require('uistubs').install({})
G_reader_settings={readSetting=function() end,saveSetting=function() end}
local Paper,Template,Document=require('paperoptions'),require('template'),require('document')
for _,value in ipairs({{spacing=0},{spacing=math.huge},{spacing=0/0},{gray=255},{gray=-1}}) do
    assert(not Paper.normalize(value),'invalid paper settings accepted')
end
local doc=Document:new('/paper');doc:setTemplate('lined');doc.paper_options={spacing=4,gray=112}
assert(doc:save());local loaded=Document:new('/paper');assert(loaded:load())
assert(loaded.paper_options.spacing==4 and loaded.paper_options.gray==112)
store['/paper'].paper_options={spacing=-5,gray=10000};assert(loaded:load() and not loaded.paper_options)
for _,id in ipairs({'lined','narrow','grid','dots','checklist'}) do
    local full,clipped=support.FakeBB.new(240,270),support.FakeBB.new(240,270)
    local area={x=0,y=0,w=240,h=270};local clip={x=31,y=42,w=95,h=113}
    Template.draw(full,id,area,1,nil,{spacing=4,gray=112})
    Template.draw(clipped,id,area,1,clip,{spacing=4,gray=112})
    local marked=0
    for y=0,269 do for x=0,239 do
        if x>=31 and x<126 and y>=42 and y<155 then
            assert(full:get(x,y)==clipped:get(x,y),'custom ruling clipping disagrees')
            if clipped:get(x,y)~=255 then assert(clipped:get(x,y)==112);marked=marked+1 end
        else assert(clipped:get(x,y)==255,'custom ruling escaped clip') end
    end end
    assert(marked>0)
end
local nb=require('notebook'):new{document=doc}
local Screen=require('device').screen;Screen.bb=support.FakeBB.new(600,800)
Screen.bb.getType=function() return 1 end
require('ffi/blitbuffer').new=function(w,h) return support.FakeBB.new(w,h) end
nb.canvas.content={x=0,y=50,w=600,h=750};nb.canvas:paintTo(Screen.bb,0,0)
local before=nb.canvas.page_render_cache[1]
nb:_setPaperOption('spacing',11);nb.canvas:paintTo(Screen.bb,0,0)
assert(nb.canvas.page_render_cache[1]~=before,'custom paper reused stale page pixels')
nb.canvas:setZoom(2);nb.canvas:paintTo(Screen.bb,0,0);local zoom=nb.canvas.zoom_cache
nb:_setPaperOption('gray',224);nb.canvas:paintTo(Screen.bb,0,0)
assert(nb.canvas.zoom_cache~=zoom,'custom paper reused stale zoom pixels')
nb:_showPaperOptions();assert(not require('safe').failed,'paper menu failed')
nb.canvas:stop()
print('paperoptions: validation, persistence, 5 clipped rulings and 1x/2x cache invalidation passed')
