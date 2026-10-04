-- Notebook-wide ruling options, bounded before they reach drawing loops.
local Paper = {}
function Paper.normalize(value)
    if type(value)~="table" then return nil end
    local spacing,gray=value.spacing,value.gray
    if type(spacing)~="number" or spacing~=spacing or spacing<3 or spacing>15 then spacing=nil end
    if type(gray)~="number" or gray~=gray or gray<96 or gray>224 then gray=nil end
    if not spacing and not gray then return nil end
    return {spacing=spacing,gray=gray and math.floor(gray)}
end
function Paper.key(value)
    value=Paper.normalize(value)
    return value and tostring(value.spacing)..":"..tostring(value.gray) or "default"
end
return Paper
