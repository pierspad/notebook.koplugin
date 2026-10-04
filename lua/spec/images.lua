package.path='./?.lua;./spec/?.lua;'..package.path
local support=require('support');local store=support.installStubs()
require('uistubs').install({})
local function be(n) return string.char(math.floor(n/16777216)%256,math.floor(n/65536)%256,math.floor(n/256)%256,n%256) end
local data='\137PNG\r\n\26\n'..be(13)..'IHDR'..be(20)..be(10)..'fixture'
local Image,Document,Renderer,Shape=require('imageobject'),require('document'),require('renderer'),require('shape')
assert(Image.info(data)==20 and not Image.info('bad'))
assert(not Image.info('\137PNG\r\n\26\n'..be(13)..'IHDR'..be(90000)..be(90000)))
local renders,freed=0,0
package.loaded['ui/renderimage']={
    renderImageData=function(_,_,_,_,w,h)
        renders=renders+1;local bb=support.FakeBB.new(w,h);bb:paintRect(0,0,w,h,70)
        bb.free=function() freed=freed+1 end;return bb
    end,
    scaleBlitBuffer=function(_,bb) return bb end,
}
assert(not Image.create(data,0,0,-1,10), 'negative image dimensions accepted')
assert(not Image.create(data,0/0,0,10,10), 'nonfinite image coordinates accepted')
local s=assert(Image.create(data,20,30,80,40))
local doc=Document:new('/images');doc:addStroke(s);assert(doc:save())
local loaded=Document:new('/images');assert(loaded:load());s=loaded:getPage().strokes[1]
assert(s.image_data==data and s.image_mime=='image/png')
local clone=s:clone();clone:translate(5,8);assert(s.x_min==20 and clone.x_min==25 and clone.image_data==data)
local resized=Shape.transform(s,'se',140,90,100,70)
assert(resized.image_data==data and resized.x_max==140 and resized.y_max==90 and s.x_max==100)
loaded:replaceStroke(s,resized);loaded:undo();assert(loaded:getPage().strokes[1]==s)
loaded:redo();assert(loaded:getPage().strokes[1]==resized)
local selected=require('lasso').findSelectedStrokes({s},{{x=25,y=35},{x=35,y=35},{x=35,y=45},{x=25,y=45}})
assert(selected[1]==s,'lasso inside image selected nothing')
local bb=support.FakeBB.new(160,120)
Renderer.drawStroke(bb,s,{x=40,y=45,w=10,h=12})
for y=0,119 do for x=0,159 do
    assert(bb:get(x,y)==((x>=40 and x<50 and y>=45 and y<57) and 70 or 255),'image escaped clip')
end end
Renderer.drawStroke(bb,s);assert(renders==1,'unchanged image decoded again')
local scaled=support.FakeBB.new(160,120);Renderer.drawPage(scaled,{strokes={s}},0.5,5,3)
assert(scaled:get(15,18)==70 and scaled:get(55,38)==255,'image scale/origin lost')
-- Both erasers leave reference images intact; selection deletion is undoable.
assert(not s:hitTest(50,50,10) and not s:splitAlongPath({50,50,60,60},10))
local marks={};loaded:eraseAlongPath({30,40,100,90},10,marks)
assert(next(marks)==nil and loaded:getPage().strokes[1]==resized,'ink eraser changed reference image')
loaded:removeStrokes({resized});assert(#loaded:getPage().strokes==0);loaded:undo();assert(#loaded:getPage().strokes==1)
-- Invalid embedded image metadata is rejected before replacing existing ink.
store['/broken']={version=1,pages={{strokes={{tool='image',shape_kind='image',image_data='bad',image_mime='image/png',n=2,pts={1,2,1,3,4,1}}}}}}
local bad=Document:new('/broken');bad:addStroke(s);assert(not bad:load() and bad:getPage().strokes[1]==s)
local malformed=s:serialize();malformed.tool='pen'
store['/broken'].pages[1].strokes={malformed}
assert(not bad:load(),'image disguised as ink was accepted')
local path=os.tmpname();assert(require('svg').toSVG(loaded,path))
local file=assert(io.open(path));local svg=file:read('*a');file:close();os.remove(path)
assert(svg:find('data:image/png;base64,',1,true),'SVG omitted embedded image')
Image.clear();assert(freed==renders,'image cache leaked buffers')
print('images: embedded persistence, independent copies, resizing/history, lasso, clipped/scaled pixels, eraser protection and SVG passed')

-- Native allocation size, rather than only the requested dimensions, bounds cache ownership.
local RenderImage=require('ui/renderimage');local old_render=RenderImage.renderImageData
local oversized_freed=false
RenderImage.renderImageData=function(_,_,_,_,w,h)
    local buffer=support.FakeBB.new(w,h);buffer.stride=40*1024*1024
    buffer.free=function() oversized_freed=true end;return buffer
end
local temporary=os.tmpname();local input=assert(io.open(temporary,'wb'));input:write(data);input:close()
assert(not Image.import(temporary,{x=0,y=0,w=100,h=100}),'oversized raster entered cache')
assert(oversized_freed,'rejected allocation leaked')
RenderImage.renderImageData=function() error('decoder failure') end
assert(not Image.import(temporary,{x=0,y=0,w=100,h=100}),'decoder failure became an image')
local old_scale=RenderImage.scaleBlitBuffer
local original_freed,scaled_freed=0,0
RenderImage.renderImageData=function(_,_,_,_,w,h)
    local buffer=support.FakeBB.new(w,h)
    buffer.free=function() original_freed=original_freed+1 end;return buffer
end
RenderImage.scaleBlitBuffer=function(_,_,w,h,free_original)
    assert(free_original==false,'scale took ownership of the original buffer')
    local buffer=support.FakeBB.new(w,h)
    buffer.free=function() scaled_freed=scaled_freed+1 end;return buffer
end
assert(Image.import(temporary,{x=0,y=0,w=100,h=100}))
assert(original_freed==1 and scaled_freed==0,'scaled buffer ownership lost')
Image.clear();assert(scaled_freed==1,'scaled cache buffer leaked')
RenderImage.scaleBlitBuffer=function() error('scaling failure') end
assert(not Image.import(temporary,{x=0,y=0,w=100,h=100}) and original_freed==2,
    'scaling failure leaked original buffer')
os.remove(temporary);RenderImage.renderImageData=old_render
RenderImage.scaleBlitBuffer=old_scale;Image.clear()
print('image allocations: oversized decoder buffers freed; failed import leaves no object')
