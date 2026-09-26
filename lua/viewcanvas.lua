-- Page/screen mapping shared by geometric tools and dirty-region restoration.
local Device=require("device")
local Renderer=require("renderer")
local Rect=require("rect")
local View={}
local Screen=Device.screen

function View:_viewPoint(x,y)
    if self.zoom<=1 then return x,y end
    return self.content.x+(x-self.zoom_x)*self.zoom,self.content.y+(y-self.zoom_y)*self.zoom
end

function View:_viewBounds(stroke)
    local x,y,w,h=stroke:getBounds()
    x,y=self:_viewPoint(x,y)
    return x,y,w*self.zoom,h*self.zoom
end

function View:_visiblePage()
    local page=self.document:getPage()
    local hidden=self.hidden_stroke or (self.transform_gesture and self.transform_gesture.original)
        or (self.shape_gesture and self.shape_gesture.original)
    if not hidden then return page end
    local strokes={}
    for _,s in ipairs(page.strokes) do if s~=hidden then strokes[#strokes+1]=s end end
    return {strokes=strokes}
end

function View:_drawViewStroke(stroke)
    if self.zoom<=1 then
        return Renderer.drawStroke(Screen.bb,stroke,self.content,Screen.isColorEnabled and Screen:isColorEnabled())
    end
    local c=self.content
    Renderer.drawPage(Screen.bb:viewport(c.x,c.y,c.w,c.h),{strokes={stroke}},self.zoom,
        -self.zoom_x*self.zoom,-self.zoom_y*self.zoom,Screen.isColorEnabled and Screen:isColorEnabled())
end

function View:_repaintScreenRegion(x,y,w,h,defer)
    if self.zoom<=1 then return self:_repaintRegion(x,y,w,h,defer) end
    local c=self.content
    x,y,w,h=Rect.clamp(x,y,w,h,c)
    if not x then return end
    local view=Screen.bb:viewport(x,y,w,h)
    view:paintRect(0,0,w,h,require("ffi/blitbuffer").COLOR_WHITE)
    local ox=c.x-self.zoom_x*self.zoom-x
    local oy=c.y-self.zoom_y*self.zoom-y
    self:_drawZoomPaper(view,{x=c.x*self.zoom+ox,y=c.y*self.zoom+oy,w=c.w*self.zoom,h=c.h*self.zoom})
    Renderer.drawPage(view,self:_visiblePage(),self.zoom,ox,oy,Screen.isColorEnabled and Screen:isColorEnabled())
    if not defer then self:_refreshNow(x,y,w,h,"ui") end
end

return View
