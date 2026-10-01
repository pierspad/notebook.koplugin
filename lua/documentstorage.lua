-- Notebook codec, validation and atomic persistence. Installs only save/load.
local Persist = require("persist")
local Stroke = require("stroke")
local Template = require("template")
local logger = require("logger")
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

local function finiteNumber(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function array(value)
    if type(value) ~= "table" then return false end
    local size = #value
    for key in pairs(value) do
        if not finiteNumber(key) or key < 1 or key > size or key % 1 ~= 0 then return false end
    end
    for i = 1, size do
        if value[i] == nil then return false end
    end
    return true
end

-- Check dense numeric points and their values in one traversal. The old
-- generic array check traversed the same large table twice before checking
-- coordinates a third time. Unique integer keys in 1..size plus count==size
-- prove density without trusting the Lua length operator on sparse arrays.
local function validPoints(points, size)
    if type(points) ~= "table" or #points ~= size then return false end
    local count = 0
    for key, value in pairs(points) do
        if type(key) ~= "number" or key < 1 or key > size or key % 1 ~= 0
            or not finiteNumber(value) then return false end
        count = count + 1
    end
    return count == size
end

local function validStroke(stroke)
    if type(stroke) ~= "table" or not finiteNumber(stroke.n)
        or stroke.n < 0 or stroke.n % 1 ~= 0 or not validPoints(stroke.pts, stroke.n * 3) then return false end
    if stroke.tool ~= nil and type(stroke.tool) ~= "string" then return false end
    if stroke.width ~= nil and (not finiteNumber(stroke.width) or stroke.width <= 0) then return false end
    if stroke.marker_parts ~= nil then
        if stroke.tool ~= "highlighter" or stroke.filled ~= true or not array(stroke.marker_parts)
            or #stroke.marker_parts == 0 then return false end
        local previous=0
        for _,last in ipairs(stroke.marker_parts) do
            if not finiteNumber(last) or last%1~=0 or last-previous<3 or last>stroke.n then return false end
            previous=last
        end
        if previous~=stroke.n then return false end
    end
    local color = stroke.color
    -- RGB ink is persisted as 0x1RRGGBB; retain legacy grayscale values too.
    if color ~= nil and (not finiteNumber(color)
        or not ((color >= 0 and color <= 255)
            or (color >= 0x1000000 and color <= 0x1FFFFFF and color % 1 == 0))) then return false end
    local tint = stroke.tint
    if tint ~= nil and (not finiteNumber(tint)
        or not ((tint >= 0 and tint <= 255)
            or (tint >= 0x1000000 and tint <= 0x1FFFFFF and tint % 1 == 0))) then return false end
    return true
end

function Document:load()
    local data = Persist:new{ path = self.path, codec = CODEC }:load()
    if type(data) ~= "table" then return false end
    if data.version ~= FORMAT_VERSION then
        logger.warn("Notebook: unsupported notebook format version", data.version)
        return false
    end

    if data.pages ~= nil and not array(data.pages) then return false end
    local pages = {}
    for i, page in ipairs(data.pages or {}) do
        if type(page) ~= "table" or (page.strokes ~= nil and not array(page.strokes)) then return false end
        local strokes = {}
        for j, s in ipairs(page.strokes or {}) do
            if not validStroke(s) then return false end
            strokes[j] = Stroke:deserialize(s)
        end
        -- A background this build does not know about is dropped rather than
        -- carried around: a notebook written by a newer version stays readable,
        -- and the page falls back to the notebook's.
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
    self.undo_stack, self.redo_stack = {}, {}
    self.dirty = false
    return true
end

end
