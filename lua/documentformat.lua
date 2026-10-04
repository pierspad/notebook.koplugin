-- Validation of persisted notebook values; no file I/O or mutations of an open document.
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
    if stroke.text ~= nil then
        if type(stroke.text)~="string" or stroke.n~=2 then return false end
        if stroke.font_size~=nil and (not finiteNumber(stroke.font_size) or stroke.font_size<=0) then return false end
    elseif stroke.tool=="text" then return false end
    if stroke.image_data ~= nil then
        local w,h,mime=require("imagecodec").info(stroke.image_data)
        if not w or not h or mime~=stroke.image_mime or stroke.tool~="image"
            or stroke.n~=2 or stroke.shape_kind~="image" then return false end
        if stroke.pts[4]<=stroke.pts[1] or stroke.pts[5]<=stroke.pts[2] then return false end
    elseif stroke.tool=="image" then return false end
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

local function dimensions(value)
    return type(value)=="table" and finiteNumber(value.w) and finiteNumber(value.h) and value.w>0 and value.h>0
end
local function background(value)
    return type(value)=="table" and type(value.file)=="string" and value.file~="" and not value.file:find("%z")
        and finiteNumber(value.page) and value.page>=1 and value.page%1==0
        and (value.size==nil or dimensions(value.size))
end
return {finiteNumber=finiteNumber,array=array,stroke=validStroke,dimensions=dimensions,background=background}
