#!/usr/bin/env luajit
package.path = "./?.lua;./spec/?.lua;" .. package.path

local support = require("support")
local uistubs = require("uistubs")
support.installStubs()

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("  ok   " .. name)
    else
        failed = failed + 1
        print("  FAIL " .. name .. "\n         " .. tostring(err))
    end
end

-- Model POSIX links at the filesystem boundary; run the real Library methods.
local function withFilesystem(fn)
    local fs = {
        ["/data"] = { mode = "directory" },
        ["/data/notebook"] = { mode = "directory" },
        ["/data/notebook/Trip"] = { mode = "directory" },
        ["/outside"] = { mode = "directory" },
        ["/outside/keep.pdf"] = { mode = "file" },
        ["/outside/sub"] = { mode = "directory" },
        ["/outside/sub/keep.pdf"] = { mode = "file" },
        ["/data/notebook/Trip/link"] = { mode = "link", target = "/outside" },
    }
    local rec = uistubs.install(fs)
    local lfs = package.loaded["libs/libkoreader-lfs"]
    local attributes, dir = lfs.attributes, lfs.dir
    local function resolve(path)
        for prefix, node in pairs(fs) do
            if node.mode == "link" and (path == prefix or path:sub(1, #prefix + 1) == prefix .. "/") then
                return node.target .. path:sub(#prefix + 1)
            end
        end
        return path
    end
    lfs.symlinkattributes = function(path, what)
        local parent, name = path:match("^(.*)/([^/]+)$")
        if parent then path = resolve(parent) .. "/" .. name end
        return attributes(path, what)
    end
    lfs.attributes = function(path, what) return attributes(resolve(path), what) end
    local walks = 0
    lfs.dir = function(path)
        walks = walks + 1
        assert(walks < 20, "directory traversal followed a link cycle")
        return dir(resolve(path))
    end
    local real_remove = os.remove
    os.remove = function(path)
        local parent, name = path:match("^(.*)/([^/]+)$")
        local resolved = parent and (resolve(parent) .. "/" .. name) or path
        if not fs[resolved] then return nil, "missing" end
        fs[resolved] = nil
        return true
    end
    package.loaded.library = nil
    local ok, err = pcall(fn, require("library"), fs)
    os.remove = real_remove
    rec.restoreRename()
    if not ok then error(err, 0) end
end

test("deleting a folder removes its link without deleting the external target", function()
    withFilesystem(function(Library, fs)
        assert(Library.deleteFolder("Trip"), "folder deletion failed")
        assert(fs["/outside/keep.pdf"], "external file was deleted")
        assert(fs["/outside/sub/keep.pdf"], "external descendant was deleted")
        assert(not fs["/data/notebook/Trip/link"], "link was not removed")
    end)
end)

test("deleting a link itself preserves its target", function()
    withFilesystem(function(Library, fs)
        assert(Library.deleteTree("/data/notebook/Trip/link"), "link deletion failed")
        assert(fs["/outside/keep.pdf"], "target contents were deleted")
        assert(not fs["/data/notebook/Trip/link"], "link was left behind")
    end)
end)

test("deleting through a linked parent is refused", function()
    withFilesystem(function(Library, fs)
        assert(not Library.deleteTree("/data/notebook/Trip/link/sub"), "linked ancestor was traversed")
        assert(fs["/outside/sub/keep.pdf"], "external descendant was deleted")
    end)
end)

test("folder destinations exclude external links and link cycles", function()
    withFilesystem(function(Library, fs)
        fs["/data/notebook/Trip/cycle"] = { mode = "link", target = "/data/notebook/Trip" }
        local folders = Library.allFolders()
        assert(#folders == 1 and folders[1].rel == "Trip", "links appeared as move destinations")
        assert(#Library.allFolders("Trip/link/sub") == 0, "linked ancestor was traversed")
    end)
end)

test("gallery listings cannot navigate into a linked directory", function()
    withFilesystem(function(Library)
        local items = Library.list("Trip")
        assert(#items == 0, "a directory link was offered as a gallery folder")
        assert(#Library.list("Trip/link/sub") == 0, "gallery listed files through a linked parent")
    end)
end)

-- Use actual files for copying; only inject the I/O failure under test.
local function copyingWithFailure(kind)
    local source, dest = os.tmpname(), os.tmpname()
    local real_open = io.open
    local f = assert(real_open(source, "wb"))
    assert(f:write("original contents")); assert(f:close())
    os.remove(dest)
    io.open = function(path, mode)
        local handle, err = real_open(path, mode)
        if not handle then return nil, err end
        if path == source and kind == "read" then
            return { read = function() return nil, "read error" end,
                     close = function() return handle:close() end }
        elseif path == source and kind == "source_close" then
            return { read = function(_, size) return handle:read(size) end,
                     close = function() handle:close(); return nil, "close error" end }
        elseif path == dest then
            return {
                write = function(_, data)
                    if kind == "write" then return nil, "No space left on device" end
                    return handle:write(data)
                end,
                close = function()
                    local ok, close_err = handle:close()
                    if kind == "close" then return nil, "No space left on device" end
                    return ok, close_err
                end,
            }
        end
        return handle
    end
    local Library = require("library")
    local ok, err = pcall(function()
        local result = Library.copyFile(source, dest)
        assert(not result, kind .. " failure was reported as a successful copy")
        local output = real_open(dest, "rb")
        if output then output:close() end
        assert(not output, "failed output was retained")
        local input = assert(real_open(source, "rb"))
        assert(input:read("*a") == "original contents", "source was changed")
        input:close()
    end)
    io.open = real_open
    os.remove(source); os.remove(dest)
    if not ok then error(err, 0) end
end

for _, kind in ipairs{ "read", "write", "close", "source_close" } do
    test("copying rejects " .. kind .. " failures and removes the partial output", function()
        copyingWithFailure(kind)
    end)
end

test("copying preserves data across several chunks", function()
    local source, dest = os.tmpname(), os.tmpname()
    local content = string.rep("abc\0", 40000)
    local f = assert(io.open(source, "wb"))
    assert(f:write(content)); assert(f:close())
    local ok, err = pcall(function()
        assert(require("library").copyFile(source, dest))
        local out = assert(io.open(dest, "rb"))
        local actual = out:read("*a"); out:close()
        assert(actual == content, "copy changed the contents")
    end)
    os.remove(source); os.remove(dest)
    if not ok then error(err, 0) end
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
