-- Bounded ownership of native text buffers. Undo history may keep a stroke
-- alive indefinitely; it must not also retain every raster ever displayed.
local Cache = {}
local entries = {}
local pixels = 0
local MAX_PIXELS = 8 * 1024 * 1024
local MAX_ENTRIES = 32

function Cache.remove(stroke)
    if not stroke then return end
    for i=#entries,1,-1 do
        if entries[i].stroke == stroke then
            pixels=pixels-entries[i].pixels
            table.remove(entries,i)
        end
    end
    if stroke._text_widget then stroke._text_widget:free() end
    stroke._text_widget,stroke._text_cache_key=nil,nil
end

function Cache.touch(stroke)
    for i=#entries,1,-1 do
        if entries[i].stroke == stroke then
            table.insert(entries,table.remove(entries,i))
            return
        end
    end
    local size=stroke._text_widget:getSize()
    local count=size.w*size.h
    -- Keep the current label even if it alone exceeds the budget. Evict it
    -- on the next insertion; freeing a widget while painting it is unsafe.
    while #entries > 0 and (pixels+count > MAX_PIXELS or #entries >= MAX_ENTRIES) do
        Cache.remove(entries[1].stroke)
    end
    entries[#entries+1]={stroke=stroke,pixels=count}
    pixels=pixels+count
end

function Cache.clear()
    while #entries > 0 do Cache.remove(entries[1].stroke) end
end

return Cache
