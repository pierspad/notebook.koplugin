--[[--
Thumbnails of a notebook's first page, cached on disk.

A gallery of cards needs a picture per notebook, and producing one means loading
the notebook and rasterising it. That is far too slow to do every time the
gallery opens, so the result is written to a PNG beside the notebooks and reused
until the notebook changes.

The cache lives in a dotted folder so that the listing ignores it, and so that
someone browsing the notebooks over USB is not confronted with it.

@module notebook.thumbnail
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Document = require("document")
local Library = require("library")
local Renderer = require("renderer")
local Template = require("template")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Thumbnail = {}

local CACHE_DIR = ".thumbs"

--- Where the cache for a given notebook lives.
function Thumbnail.pathFor(path)
    -- The notebook's own path decides the file name, so notebooks of the same
    -- name in different folders do not collide. Slashes are not legal in a file
    -- name, so they are folded away.
    -- Relative to the notebook root, so that the key is the same wherever that
    -- root happens to be -- it is one of two names, depending on whether this
    -- install predates the plugin having its own name.
    local root = Library.root()
    local key = path:sub(1, #root) == root and path:sub(#root + 2) or path
    key = key:gsub("[/\\]", "_")
    return Library.abs(CACHE_DIR) .. "/" .. key .. ".png"
end

--- When a notebook was last written, or nil if it is not there.
function Thumbnail.stamp(notebook_path)
    local src = lfs.attributes(notebook_path)
    return src and src.modification or nil
end

--[[--
Returns an up-to-date thumbnail for a notebook if one already exists.

Two file stats and nothing else: no notebook is opened and nothing is drawn.
This is what the gallery asks while it is laying out, so that building a screen
of cards costs the same whether the notebooks behind them are empty or hold a
thousand strokes.
--]]
function Thumbnail.cached(notebook_path)
    local src = lfs.attributes(notebook_path)
    if not src then return nil end

    local cache = Thumbnail.pathFor(notebook_path)
    local cached = lfs.attributes(cache)
    if cached and cached.modification >= src.modification then
        return cache
    end
    return nil
end

--[[--
Returns the path to a thumbnail for a notebook, generating it if needed.

Rasterising means loading the whole notebook, so this is far too slow to call
while a screen is being laid out; see `Thumbnail.cached`.

Returns nil when the notebook cannot be read or has nothing on its first page:
an empty picture says less than no picture, and the caller can show the notebook
as blank instead.
--]]
function Thumbnail.get(notebook_path, w, h, page_w, page_h)
    local existing = Thumbnail.cached(notebook_path)
    if existing then return existing end

    if not lfs.attributes(notebook_path) then return nil end
    local cache = Thumbnail.pathFor(notebook_path)

    Library.ensureDir(CACHE_DIR)

    local doc = Document:new(notebook_path)
    if not doc:load() then
        logger.warn("Notebook: cannot read notebook for thumbnail:", notebook_path)
        return nil
    end

    -- The page you were last on, not the first one. A notebook you have been
    -- working through is recognised by where you left off; its first page may
    -- have been written weeks ago, or be blank.
    local index = doc.current_page or 1
    local page = doc.pages and doc.pages[index]
    if not page or #page.strokes == 0 then
        -- Fall back to the first page with anything on it, so a notebook whose
        -- current page happens to be empty still shows something. The index
        -- moves with it, so the background drawn is that page's own.
        for i, candidate in ipairs(doc.pages or {}) do
            if #candidate.strokes > 0 then
                page, index = candidate, i
                break
            end
        end
    end
    if not page then return nil end

    -- Nothing written, but ruled or squared paper: still worth a picture, and
    -- the card is how you see at a glance what a notebook is for. Only a blank
    -- page with nothing on it has nothing to show.
    local template = doc:templateFor(index)
    if #page.strokes == 0 and (not template or template == "blank") then
        return nil
    end

    -- Fit the page into the card, keeping its proportions.
    local scale = math.min(w / page_w, h / page_h)

    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_WHITE)
    -- The background too, so a card looks like the page it stands for.
    Template.draw(bb, doc:templateFor(index),
        { x = 0, y = 0, w = w, h = h }, scale)
    Renderer.drawPage(bb, page, scale)

    local ok = pcall(function() bb:writePNG(cache) end)
    if bb.free then bb:free() end

    if not ok then
        logger.warn("Notebook: cannot write thumbnail:", cache)
        return nil
    end
    return cache
end

--- Drops a notebook's cached thumbnail, after it is deleted or renamed.
function Thumbnail.forget(notebook_path)
    os.remove(Thumbnail.pathFor(notebook_path))
end

return Thumbnail
