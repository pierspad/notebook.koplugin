-- Native pixel/PNG equivalence for preview loading and PDF cache changes.
-- Arguments: current Lua tree, baseline Lua tree, disposable directory.
require("setupkoenv")
local tmp=assert(require("ffi/util").realpath(assert(arg[3])))
G_defaults=require("luadefaults"):open()
G_reader_settings=require("luasettings"):open(tmp.."/settings.lua")
local Device=require("device")
for _,name in ipairs({"refreshUI","refreshFast","refreshFull","refreshPartial","refreshNoMerge","refreshA2"}) do
    Device.screen[name]=function() end
end
require("document/canvascontext"):init(Device)
local current=dofile(arg[1].."/loader.lua")(arg[1])
local baseline=dofile(arg[2].."/loader.lua")(arg[2])
local lfs=require("libs/libkoreader-lfs")
local roots={tmp.."/current",tmp.."/baseline"}
for i,load in ipairs({current,baseline}) do
    assert(lfs.mkdir(roots[i]))
    load("library").root=function() return roots[i] end
end
local Document,Stroke=current("document"),current("stroke")
local count=0
local function bytes(path)
    local f=assert(io.open(path,"rb"));local s=f:read("*a");assert(f:close());return s
end
local function duplicate(path)
    local target=roots[2].."/"..path:match("([^/]+)$")
    local f=assert(io.open(target,"wb"));assert(f:write(bytes(path)));assert(f:close());return target
end
for _,case in ipairs({"current", "fallback", "empty-grid", "text-shapes", "pdf"}) do
    local d=Document:new(roots[1].."/"..case..".scribe")
    d.content_origin={x=5,y=45};d.page_size={w=600,h=800}
    for page=1,4 do
        if page>1 then d:addPage() end
        if case~="empty-grid" and (case~="fallback" or page==1) then
            for _,style in ipairs({"fineliner","fountain","pencil","highlighter"}) do
                local s=Stroke:new{tool=style=="highlighter" and style or "pen",pen_style=style,width=12}
                for i=1,40 do s:addPoint(30+i*10,100+page*80+math.sin(i/3)*20,i%10/10) end
                d:addStroke(s)
            end
        end
    end
    d:goToPage(3);d.pages[1].template="dots";d.pages[3].template="grid"
    if case=="text-shapes" then
        d:addStroke(current("textobject").create("Caffè Ελληνικά 日本語",20,100,500,24,{font_family="sans"}))
        d:addStroke(current("shape").create("circle",100,200,300,400,4,0,true))
    elseif case=="pdf" then
        local file=tmp.."/background.pdf"
        assert(current("export").toPDF(d,file,{width=600,height=800}))
        d.pages[3].background={file=file,page=2}
    end
    assert(d:save());local other=duplicate(d.path)
    local a=assert(current("thumbnail").get(d.path,186,248,650,900))
    local b=assert(baseline("thumbnail").get(other,186,248,650,900))
    assert(bytes(a)==bytes(b),"preview PNG changed: "..case)
    count=count+1
end
local BB=require("ffi/blitbuffer")
for _,kind in ipairs({BB.TYPE_BB8,BB.TYPE_BBRGB32}) do
    for rotation=0,3 do
        local a,b=BB.new(320,400,kind),BB.new(320,400,kind)
        a:setRotation(rotation);b:setRotation(rotation)
        for _,n in ipairs({1,2,1}) do
            a:fill(BB.COLOR_WHITE);b:fill(BB.COLOR_WHITE)
            local background={file=tmp.."/background.pdf",page=n}
            local area={x=-17,y=11,w=300,h=380}
            local clip={x=9,y=19,w=250,h=290}
            current("pdfbackground").draw(a,background,area,clip)
            baseline("pdfbackground").draw(b,background,area,clip)
            for y=0,a:getHeight()-1 do for x=0,a:getWidth()-1 do
                local p,q=a:getPixel(x,y),b:getPixel(x,y)
                assert(p:getR()==q:getR() and p:getG()==q:getG() and p:getB()==q:getB(),"PDF cached pixels changed")
            end end
            count=count+1
        end
        a:free();b:free()
    end
end
current("pdfbackground").clear();baseline("pdfbackground").clear()
if Device.input and Device.input.teardown then Device.input:teardown() end
print("Preview/PDF cache: "..count.." native PNG/pixel comparisons passed")
