-- Notebook codec, validation and atomic persistence. Installs only save/load.
local Persist = require("persist")
local Stroke = require("stroke")
local Template = require("template")
local logger = require("logger")
local Format=require("documentformat")
local finiteNumber,array,validStroke=Format.finiteNumber,Format.array,Format.stroke
local FORMAT_VERSION, CODEC = 1, "bitser"
return function(Document)
-- Persistence ----------------------------------------------------------------

function Document:save()
    if not self.path then return false, "no path" end

    local pages = {}
    for i, page in ipairs(self.pages) do
        local strokes = page._serialized
        if not strokes then
            strokes = {}
            for j, stroke in ipairs(page.strokes) do
                strokes[j] = stroke:serialize()
            end
            page._serialized = strokes
        end
        pages[i] = { strokes = strokes, template = page.template, background = page.background }
    end

    --[[
    Written beside the notebook and moved into place, never over it.

    Persist opens the destination for writing, which truncates it, and only then
    starts putting bytes in. Everything between those two moments is a notebook
    that is neither the old one nor the new one, and this runs every couple of
    seconds while someone is writing -- so the window is small but it is open
    most of the time a notebook is being used. Losing power in it, or being
    killed for memory, took the whole notebook rather than the last few strokes.

    A rename within a directory is atomic, so the file at the notebook's path is
    always one complete save or the other.
    --]]
    local tmp = self.path .. ".saving"
    local ok, err = Persist:new{ path = tmp, codec = CODEC }:save{
        version = FORMAT_VERSION,
        pages = pages,
        current_page = self.current_page,
        template = self.template,
        content_origin = self.content_origin,
        page_size = self.page_size,
        paper_options = self.paper_options,
    }

    if ok then
        ok, err = os.rename(tmp, self.path)
        if not ok then
            -- The old notebook is still there and still whole; the half-written
            -- one is what goes.
            os.remove(tmp)
        end
    else
        os.remove(tmp)
    end

    if ok then
        self.dirty = false
    else
        logger.warn("Notebook: failed to save notebook:", err)
    end
    return ok, err
end

function Document:load()
    local data = Persist:new{ path = self.path, codec = CODEC }:load()
    if type(data) ~= "table" then return false end
    if data.version ~= FORMAT_VERSION then
        logger.warn("Notebook: unsupported notebook format version", data.version)
        return false
    end

    if data.pages ~= nil and not array(data.pages) then return false end
    if data.page_size~=nil and not Format.dimensions(data.page_size) then return false end
    local pages = {}
    for i, page in ipairs(data.pages or {}) do
        if type(page) ~= "table" or (page.strokes ~= nil and not array(page.strokes)) then return false end
        if page.background~=nil and not Format.background(page.background) then return false end
        local strokes = {}
        for j, s in ipairs(page.strokes or {}) do
            if not validStroke(s) then return false end
            strokes[j] = Stroke:deserialize(s)
        end
        -- Unknown paper templates fall back without changing validated PDF metadata.
        local template = Template.isKnown(page.template) and page.template or nil
        pages[i] = { strokes = strokes, template = template, background = page.background }
    end
    if #pages == 0 then pages = { { strokes = {} } } end

    -- Replace the open state only after the whole notebook has been validated.
    self.pages = pages
    self.template = Template.isKnown(data.template) and data.template or Template.DEFAULT
    self.page_size = data.page_size
    -- Absent in notebooks written before the origin was recorded; see
    -- Document:contentOrigin.
    local origin = data.content_origin
    local x = type(origin) == "table" and tonumber(origin.x)
    local y = type(origin) == "table" and tonumber(origin.y)
    self.content_origin = { x = finiteNumber(x) and x or 0, y = finiteNumber(y) and y or 0 }
    local current = data.current_page
    if not finiteNumber(current) or current % 1 ~= 0 then current = 1 end
    self.current_page = math.max(1, math.min(current, #pages))
    self.paper_options = require("paperoptions").normalize(data.paper_options)
    self.undo_stack, self.redo_stack = {}, {}
    self.dirty = false
    return true
end

end
