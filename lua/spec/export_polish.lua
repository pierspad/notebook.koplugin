local support = require('spec/support')
support.installStubs()
local ffi = require('ffi')
local Export = require('export')
local Renderer = require('renderer')
local Template = require('template')
local failures = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    print((ok and 'PASS ' or 'FAIL ') .. name .. (ok and '' or ': ' .. tostring(err)))
    if not ok then failures = failures + 1 end
end
local function read(path)
    local f = assert(io.open(path, 'rb')); local s = f:read('*a'); f:close(); return s
end
local path = os.tmpname()
local doc = { pages = {{}} , pageCount = function() return 1 end,
    contentOrigin = function() return 2, 3 end, templateFor = function() return 'ruled' end }
local draw, template = Renderer.drawPage, Template.draw
local ink, paper
Renderer.drawPage = function(bb, page, scale, x, y) ink = {x, y} end
Template.draw = function(bb, kind, area) paper = area end
test('default export crops origin and aligns template and ink', function()
    assert(Export.toPDF(doc, path, {width=10, height=12}))
    local pdf = read(path)
    assert(pdf:find('/Width 8\n', 1, true) and pdf:find('/Height 9\n', 1, true), 'uncropped raster')
    assert(ink[1] == -2 and ink[2] == -3 and paper.x == 0 and paper.y == 0)
end)
test('explicit area remains authoritative', function()
    assert(Export.toPDF(doc, path, {content_area={x=4,y=5,w=6,h=7}}))
    assert(ink[1] == -4 and ink[2] == -5 and paper.x == 0 and paper.y == 0)
end)
test('failed render preserves destination', function()
    local f=assert(io.open(path,'wb')); f:write('original'); f:close()
    Renderer.drawPage = function() error('render failed') end
    assert(not Export.toPDF(doc,path,{width=10,height=12}))
    assert(read(path)=='original', 'destination was overwritten')
end)
Renderer.drawPage, Template.draw = draw, template
test('BB8 pointer rows preserve padding', function()
    local pixels=ffi.new('uint8_t[8]', {0,127,255,42,9,11,13,42})
    local bb={getType=function() return 1 end,getRotation=function() return 0 end,
        getInverse=function() return 0 end,getPixelP=function(_,x,y) return pixels+y*4+x end,
        getPixel=function() error('slow pixel path') end}
    assert(Export.packPage(bb,3,2)==string.char(0,127,255,9,11,13))
end)
test('non BB8 pointers use grayscale conversion', function()
    local bb={getType=function() return 2 end,getPixelP=function() error('unsafe pointer path') end,
        getPixel=function() return {getColor8=function() return {a=77} end} end}
    assert(Export.packPage(bb,2,1)==string.char(77,77))
end)
test('RLE decodes exact bytes at chunk boundaries', function()
    local function decode(s)
        local out={};local i=1
        while true do local n=s:byte(i);i=i+1
            if n==128 then break elseif n<128 then out[#out+1]=s:sub(i,i+n);i=i+n+1
            else out[#out+1]=s:sub(i,i):rep(257-n);i=i+1 end
        end
        return table.concat(out)
    end
    for _,n in ipairs({0,1,2,127,128,129,256,1025}) do
        local bytes={};for i=1,n do bytes[i]=string.char(i%256) end
        local s=table.concat(bytes)..string.rep('x',n)
        assert(decode(Export.encodeRLE(s))==s)
    end
end)
test('incremental export advances once per real phase', function()
    Renderer.drawPage = function() end
    local out = os.tmpname()
    os.remove(out)
    local job = assert(Export.beginPDF(doc, out, {width=10,height=12}))
    assert(job.total == 3 and job.completed == 0 and job.phase == 1)
    assert(job:step() == 'working')
    assert(job.completed == 1 and job.phase == 2)
    assert(job:step() == 'working')
    assert(job.completed == 2 and job.phase == 3)
    assert(job:step() == 'done')
    assert(job.completed == 3 and read(out):sub(1,9) == '%PDF-1.4\n')
    os.remove(out)
end)
test('cancelling an incremental export removes only its temporary file', function()
    Renderer.drawPage = function() end
    local out = os.tmpname()
    local f=assert(io.open(out,'wb')); f:write('existing'); f:close()
    local job = assert(Export.beginPDF(doc, out, {width=10,height=12}))
    assert(job:step() == 'working')
    job:cancel()
    assert(job:step() == 'cancelled')
    assert(read(out) == 'existing', 'cancel overwrote destination')
    assert(io.open(out .. '.tmp','rb') == nil, 'partial export was left behind')
    os.remove(out)
end)
os.remove(path)
assert(failures==0, failures .. ' export regression(s)')
