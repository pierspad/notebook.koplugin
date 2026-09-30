#!/usr/bin/env luajit
package.path = "./?.lua;./spec/?.lua;" .. package.path
local source = "/notebook.scribe"
local contents, fault, closes
package.loaded.datastorage = {getDataDir=function() return "/mock" end}
package.loaded.library = {}
package.loaded["libs/libkoreader-lfs"] = {
    attributes=function(path)
        if path == source then return {mode="file",size=#contents,modification=100} end
        return "directory"
    end,
    mkdir=function() return true end,
}
local Share = require("share")
local real_open = io.open
local passed, failed = 0, 0
local function test(name, fn)
    contents, fault, closes = "notebook A", nil, 0
    io.open = function(path, mode)
        assert(path == source and mode == "rb")
        if fault == "open" then return nil, "open failed" end
        local offset = 1
        return {
            read=function(_, count)
                if fault == "read" and offset > 1 then return nil, "read failed" end
                if offset > #contents then return nil end
                local chunk = contents:sub(offset, offset+count-1)
                offset = offset + #chunk
                return chunk
            end,
            close=function()
                closes=closes+1
                if fault == "close" then return nil, "close failed" end
                return true
            end,
        }
    end
    local ok, err = pcall(fn)
    io.open = real_open
    if ok then passed=passed+1; print("  ok   "..name)
    else failed=failed+1; print("  FAIL "..name.."\n         "..tostring(err)) end
end

test("unchanged notebook produces the same export cache path", function()
    local first=assert(Share.cachedExport(source,"Book","pdf"))
    assert(first==Share.cachedExport(source,"Book","pdf"))
    assert(closes==2,"source descriptors leaked")
end)
test("same size and timestamp edits invalidate the export cache", function()
    local first=assert(Share.cachedExport(source,"Book","pdf"))
    contents="notebook B"
    assert(first~=Share.cachedExport(source,"Book","pdf"),"stale export key")
end)
test("content past the first read chunk changes the key", function()
    contents=string.rep("a",65536).."b"
    local first=assert(Share.cachedExport(source,"Book","pdf"))
    contents=string.rep("a",65536).."c"
    assert(first~=Share.cachedExport(source,"Book","pdf"))
end)
test("format and notebook name distinguish cached output files", function()
    local first=assert(Share.cachedExport(source,"Book","pdf"))
    assert(first~=Share.cachedExport(source,"Book","xopp"))
    assert(first~=Share.cachedExport(source,"Other","pdf"))
end)
for _, kind in ipairs{"open","read","close"} do
    test("a source "..kind.." failure cannot produce a cache key", function()
        fault=kind
        assert(Share.cachedExport(source,"Book","pdf")==nil,"incomplete content accepted as cache key")
        assert(closes==(kind=="open" and 0 or 1),"source descriptor close count")
    end)
end
print(string.format("\n%d passed, %d failed",passed,failed))
os.exit(failed==0 and 0 or 1)
