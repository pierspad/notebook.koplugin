#!/usr/bin/env luajit
package.path = "./?.lua;./spec/?.lua;" .. package.path
local store = require("support").installStubs()
local Document = require("document")
local Stroke = require("stroke")
local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = copy(item) end
    return out
end
local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; print("  ok   " .. name)
    else failed = failed + 1; print("  FAIL " .. name .. "\n         " .. tostring(err)) end
end

for _, case in ipairs{
    { name = "zero", value = 0, want = 1 },
    { name = "negative", value = -2, want = 1 },
    { name = "fraction", value = 1.5, want = 1 },
    { name = "text", value = "page", want = 1 },
    { name = "infinity", value = math.huge, want = 1 },
    { name = "NaN", value = 0/0, want = 1 },
    { name = "above last", value = 9, want = 2 },
    { name = "valid", value = 2, want = 2 },
} do
    test("loaded " .. case.name .. " page index selects a usable page", function()
        store["/index"] = { version = 1, current_page = case.value,
            pages = { { strokes = {} }, { strokes = {} } } }
        local doc = Document:new("/index")
        assert(doc:load(), "could not load notebook")
        assert(doc.current_page == case.want, "wrong current page: " .. tostring(doc.current_page))
        local stroke = Stroke:new(); stroke:addPoint(1, 2, 1)
        doc:addStroke(stroke)
        assert(doc.pages[case.want].strokes[1] == stroke, "loaded page could not accept ink")
    end)
end

for _, case in ipairs{
    { name = "non-table document", data = true },
    { name = "non-table pages", data = { version = 1, pages = true } },
    { name = "non-table page", data = { version = 1, pages = { true } } },
    { name = "non-table strokes", data = { version = 1, pages = { { strokes = true } } } },
    { name = "incomplete points", stroke = { n = 2, pts = { 1, 2, 1 }, width = 3 } },
    { name = "nonfinite coordinates", stroke = { n = 1, pts = { math.huge, 2, 1 }, width = 3 } },
    { name = "invalid width", stroke = { n = 1, pts = { 1, 2, 1 }, width = -1 } },
} do
    test("rejecting " .. case.name .. " preserves the open document", function()
        store["/broken"] = case.data or { version = 1, pages = { { strokes = { case.stroke } } } }
        local doc = Document:new("/broken")
        local stroke = Stroke:new(); stroke:addPoint(5, 6, 1)
        doc:addStroke(stroke)
        local page = doc:getPage()
        assert(doc:load() == false, "malformed notebook was accepted")
        assert(doc:getPage() == page and page.strokes[1] == stroke, "existing ink was replaced")
        assert(doc.dirty and doc:canUndo(), "existing edit state was lost")
    end)
end

test("nonfinite content origin cannot poison loaded coordinates", function()
    store["/origin"] = { version = 1, pages = {}, content_origin = { x = math.huge, y = 0/0 } }
    local doc = Document:new("/origin")
    assert(doc:load())
    local x, y = doc:contentOrigin()
    assert(x == 0 and y == 0, "nonfinite origin was retained")
end)

test("colored strokes retain RGB values through a document save and load", function()
    local doc = Document:new("/rgb")
    for _, color in ipairs{ 0x1000000, 0x1E53935, 0x1FFFFFF } do
        local stroke = Stroke:new{ color = color }
        stroke:addPoint(10, 20, 0.5); stroke:addPoint(30, 40, 1)
        doc:addStroke(stroke)
    end
    assert(doc:save())
    store["/rgb"] = copy(store["/rgb"])
    local loaded = Document:new("/rgb")
    assert(loaded:load(), "new RGB notebook was rejected by legacy validation")
    for i, stroke in ipairs(doc:getPage().strokes) do
        assert(loaded:getPage().strokes[i].color == stroke.color, "RGB color was changed")
    end
end)

test("PDF backgrounds, page dimensions and editable objects survive validated loading", function()
    local doc = Document:new("/modern")
    doc.page_size = { w = 1000, h = 1400 }
    doc:getPage().background = { file = "/source.pdf", page = 2, size = { w = 600, h = 800 } }
    doc:getPage().template = "grid"
    local text = Stroke:new{ tool = "text", shape_kind = "text", text = "Ciao", font_size = 26,
        font_family = "mono", text_bold = true, text_italic = true,
        text_underline = true, text_background = true }
    text:addPoint(10, 20); text:addPoint(110, 60)
    local shape = Stroke:new{ tool = "pen", shape_kind = "rectangle", filled = true, pen_style = "fountain" }
    shape:addPoint(20, 70); shape:addPoint(120, 170)
    doc:addStroke(text); doc:addStroke(shape)
    assert(doc:save())
    store["/modern"] = copy(store["/modern"])
    local loaded = Document:new("/modern")
    assert(loaded:load())
    local page = loaded:getPage()
    assert(page.background.file == "/source.pdf" and page.background.page == 2
        and page.background.size.w == 600 and page.template == "grid", "PDF/template metadata was lost")
    assert(loaded.page_size.w == 1000 and loaded.page_size.h == 1400, "page dimensions were lost")
    local label, figure = page.strokes[1], page.strokes[2]
    assert(label.text == "Ciao" and label.shape_kind == "text" and label.font_size == 26
        and label.font_family == "mono" and label.text_bold and label.text_italic
        and label.text_underline and label.text_background, "editable text styles were lost")
    assert(figure.shape_kind == "rectangle" and figure.filled and figure.pen_style == "fountain",
        "shape metadata was lost")
    loaded:removeStrokes{label}; loaded:undo(); loaded:redo()
    assert(#loaded:getPage().strokes == 1 and loaded:getPage().strokes[1] == figure,
        "new undo/redo broke after loading")
end)

test("RGB highlighter tints survive document persistence", function()
    local doc = Document:new("/marker-rgb")
    for _, tint in ipairs{0, 160, 255, 0x1000000, 0x1FDD835, 0x1FFFFFF} do
        local stroke = Stroke:new{tool="highlighter", width=24, tint=tint}
        stroke:addPoint(10,20,1); stroke:addPoint(30,40,1)
        doc:addStroke(stroke)
    end
    assert(doc:save())
    store["/marker-rgb"] = copy(store["/marker-rgb"])
    local loaded = Document:new("/marker-rgb")
    assert(loaded:load(), "RGB marker notebook was rejected")
    for i, stroke in ipairs(doc:getPage().strokes) do
        assert(loaded:getPage().strokes[i].tint == stroke.tint, "marker tint changed")
    end
end)

for _, color in ipairs{-1, 256, 0xFFFFFF, 0x2000000, 0x1000000+0.5, math.huge} do
    for _, field in ipairs{"color", "tint"} do
        test("rejects out-of-contract " .. field .. " " .. tostring(color), function()
            local stroke = {n=1, pts={1,2,1}, width=3, [field]=color}
            store["/bad-color"] = {version=1, pages={{strokes={stroke}}}}
            assert(not Document:new("/bad-color"):load(), "invalid ink accepted")
        end)
    end
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
