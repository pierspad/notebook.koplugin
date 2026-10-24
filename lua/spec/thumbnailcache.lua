#!/usr/bin/env luajit
package.path = "./?.lua;./spec/?.lua;" .. package.path

local store = require("support").installStubs()
local fs = {
    ["/data"] = { mode = "directory", modification = 1 },
    ["/data/notebook"] = { mode = "directory", modification = 1 },
    ["/data/notebook/empty.scribe"] = {
        mode = "file", dev = 1, ino = 17, size = 32,
        modification = 100, change = 100,
    },
}
local recorder = require("uistubs").install(fs)
local path = "/data/notebook/empty.scribe"
local cache_prefix = "/data/notebook/.thumbs/"
local real_open, real_remove = io.open, os.remove
local memory_files = fs
io.open = function(name, mode)
    if name:sub(1, #cache_prefix) == cache_prefix then
        if mode == "rb" then
            local entry = memory_files[name]
            if not entry then return nil, "No such file" end
            local content = entry.content or ""
            return {
                read = function(_, format)
                    if format == "*a" then return content end
                    if type(format) == "number" then return content:sub(1, format) end
                    return nil
                end,
                close = function() return true end,
            }
        elseif mode == "wb" then
            local content = ""
            return {
                write = function(_, bytes) content = content .. bytes; return true end,
                close = function()
                    memory_files[name] = {
                        mode = "file", size = #content,
                        modification = 101, content = content,
                    }
                    return true
                end,
            }
        end
    end
    return real_open(name, mode)
end
os.remove = function(name)
    if memory_files[name] then memory_files[name] = nil; return true end
    return real_remove(name)
end

package.loaded.library = {
    root = function() return "/data/notebook" end,
    abs = function(rel) return "/data/notebook/" .. rel end,
    ensureDir = function(rel)
        fs["/data/notebook/" .. rel] = { mode = "directory", modification = 1 }
        return true
    end,
}
local loads, load_ok, template_name, on_load = 0, true, "blank", nil
local doc = {
    pages = { { strokes = {} } }, current_page = 1,
    load = function()
        loads = loads + 1
        if on_load then return on_load() end
        return load_ok
    end,
    templateFor = function() return template_name end,
    contentOrigin = function() return 0, 0 end,
}
package.loaded.document = { new = function() return doc end }
package.loaded["ffi/blitbuffer"] = {
    TYPE_BB8 = 1, COLOR_WHITE = 255,
    new = function()
        return {
            fill = function() end,
            free = function() end,
            writePNG = function(_, name)
                fs[name] = { mode = "file", size = 16, modification = 101 }
            end,
        }
    end,
}
package.loaded.renderer = { drawPage = function() end }
package.loaded.template = {
    DEFAULT = "blank",
    isKnown = function(id) return id == "blank" or id == "grid" end,
    draw = function() end,
}
package.loaded["thumbnail"] = nil
local Thumbnail = require("thumbnail")

-- Empty notebooks are a negative cache entry, not a PNG full of blank pixels.
assert(Thumbnail.get(path, 40, 50, 100, 200) == nil)
assert(Thumbnail.get(path, 40, 50, 100, 200) == nil)
assert(loads == 1, "the empty notebook was loaded again despite its negative cache")
assert(Thumbnail.emptyCached(path), "the empty notebook marker is not current")
local marker = Thumbnail.pathFor(path) .. ".empty"
assert(fs[marker] and fs[marker].content, "the marker was not persisted")

-- Every available file identity/content field participates in invalidation.
for _, change in ipairs{
    { "dev", 2 }, { "ino", 18 }, { "size", 33 },
    { "modification", 101 }, { "change", 102 },
} do
    assert(Thumbnail.get(path, 40, 50, 100, 200) == nil)
    assert(Thumbnail.emptyCached(path), "marker was not refreshed before invalidation")
    fs[path][change[1]] = change[2]
    assert(not Thumbnail.emptyCached(path), "marker survived a source " .. change[1] .. " change")
    assert(not fs[marker], "stale marker was not removed")
end

assert(Thumbnail.get(path, 40, 50, 100, 200) == nil)
assert(Thumbnail.emptyCached(path), "empty marker was not recreated")
Thumbnail.forget(path)
assert(not fs[marker] and not Thumbnail.emptyCached(path), "forget left the empty marker behind")

-- Failed reads are not negative cache results and should be retried.
local broken = "/data/notebook/broken.scribe"
fs[broken] = { mode = "file", size = 4, modification = 200, change = 200, ino = 19 }
load_ok = false
local before_broken = loads
assert(Thumbnail.get(broken, 40, 50, 100, 200) == nil)
assert(not Thumbnail.emptyCached(broken), "unreadable notebook received an empty marker")
assert(Thumbnail.get(broken, 40, 50, 100, 200) == nil)
assert(loads == before_broken + 2, "unreadable notebook was incorrectly cached")

-- If the source changes during the read, do not persist a result for either
-- version of the file.
local unstable = "/data/notebook/unstable.scribe"
fs[unstable] = { mode = "file", size = 9, modification = 250, change = 250, ino = 21 }
on_load = function()
    fs[unstable].change = fs[unstable].change + 1
    return true
end
assert(Thumbnail.get(unstable, 40, 50, 100, 200) == nil)
assert(not Thumbnail.emptyCached(unstable), "source drift during load received a marker")
on_load = nil

-- Minimal filesystems without size or content timestamps still generate a
-- real thumbnail, but cannot safely retain a negative result across sessions.
local minimal = "/data/notebook/minimal.scribe"
fs[minimal] = { mode = "file", dev = 1, ino = 22 }
assert(Thumbnail.stamp(minimal) == nil, "inode alone was accepted as a content stamp")
local before_minimal = loads
assert(Thumbnail.get(minimal, 40, 50, 100, 200) == nil)
assert(not Thumbnail.emptyCached(minimal), "unstampable notebook received a marker")
assert(Thumbnail.get(minimal, 40, 50, 100, 200) == nil)
assert(loads == before_minimal + 2, "unstampable notebook stopped retrying")

-- A blank page that has ruling or a background is still a real thumbnail.
local ruled = "/data/notebook/ruled.scribe"
fs[ruled] = { mode = "file", size = 8, modification = 300, change = 300, ino = 20 }
load_ok = true
template_name = "grid"
assert(Thumbnail.get(ruled, 40, 50, 100, 200) == Thumbnail.pathFor(ruled))
assert(not Thumbnail.emptyCached(ruled), "ruled blank page was marked empty")

-- Invoke production thumbnail and document storage modules on serialized page
-- data; only the fallback page should become live Stroke objects.
local production_path = "/data/notebook/multipage.scribe"
fs[production_path] = {
    mode = "file", dev = 1, ino = 31, size = 400, modification = 400, change = 400,
}
local Stroke = require("stroke")
local function serializedStroke(x)
    local stroke = Stroke:new()
    stroke:addPoint(x, 2, 1)
    return stroke:serialize()
end
store[production_path] = {
    version = 1, current_page = 1, template = "blank",
    page_size = { w = 100, h = 200 },
    pages = {
        { strokes = {}, template = "blank" },
        { strokes = { serializedStroke(1), serializedStroke(2) }, template = "grid",
            background = { file = "/source.pdf", page = 1, size = { w = 100, h = 200 } } },
        { strokes = { serializedStroke(3), serializedStroke(4), serializedStroke(5) } },
    },
}
package.loaded.document = nil
package.loaded.documentstorage = nil
package.loaded.thumbnail = nil
local real_thumbnail = require("thumbnail")
local deserialize = Stroke.deserialize
local deserialized, rendered, template_drawn, pdf_drawn = 0, 0, nil, nil
Stroke.deserialize = function(self, data)
    deserialized = deserialized + 1
    return deserialize(self, data)
end
package.loaded.renderer.drawPage = function(_, page)
    rendered = #page.strokes
end
package.loaded.template.draw = function(_, id) template_drawn = id end
package.loaded.pdfbackground = {
    draw = function(_, background) pdf_drawn = background.file end,
}
assert(real_thumbnail.get(production_path, 40, 50, 100, 200))
assert(deserialized == 2, "thumbnail load materialized strokes outside the selected page")
assert(rendered == 2 and template_drawn == "grid" and pdf_drawn == "/source.pdf",
    "fallback page did not retain its strokes, paper style, or PDF background")

local current_path = "/data/notebook/currentpage.scribe"
fs[current_path] = {
    mode = "file", dev = 1, ino = 32, size = 300, modification = 410, change = 410,
}
store[current_path] = {
    version = 1, current_page = 2, template = "blank",
    pages = {
        { strokes = { serializedStroke(10), serializedStroke(11) } },
        { strokes = { serializedStroke(12) }, template = "grid" },
    },
}
deserialized, rendered, template_drawn, pdf_drawn = 0, 0, nil, nil
assert(real_thumbnail.get(current_path, 40, 50, 100, 200))
assert(deserialized == 1 and rendered == 1 and template_drawn == "grid",
    "thumbnail did not prefer and render the current page")

-- A corrupt unselected page still invalidates the whole notebook, and no
-- partially validated page is deserialized or rendered.
local corrupt_path = "/data/notebook/corrupt.scribe"
fs[corrupt_path] = {
    mode = "file", dev = 1, ino = 33, size = 100, modification = 420, change = 420,
}
store[corrupt_path] = {
    version = 1, current_page = 2,
    pages = {
        { strokes = { { n = 2, pts = { 1, 2, 1 }, width = 3 } } },
        { strokes = { serializedStroke(13) } },
    },
}
deserialized, rendered = 0, 0
assert(real_thumbnail.get(corrupt_path, 40, 50, 100, 200) == nil)
assert(deserialized == 0 and rendered == 0, "corrupt unselected page was ignored or partially loaded")
assert(not real_thumbnail.emptyCached(corrupt_path), "corrupt notebook received an empty marker")
Stroke.deserialize = deserialize

io.open, os.remove = real_open, real_remove
recorder.restoreRename()
print("thumbnailcache: negative entries, stamp invalidation, corrupt and ruled notebooks passed")
