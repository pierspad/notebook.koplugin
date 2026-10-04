-- A small persisted MRU list; missing notebooks are removed without opening them.
local Library = require("library")
local lfs = require("libs/libkoreader-lfs")
local Recents = {}
local KEY, LIMIT = "notebook_recent", 8
local function valid(rel)
    if type(rel) ~= "string" or rel:sub(1,1)=="/" or not rel:match("%.scribe$") then return false end
    for part in rel:gmatch("[^/]+") do if part==".." or part=="." then return false end end
    return not rel:find("%z") and not rel:find("//",1,true)
end
function Recents.list(exclude)
    local list, seen = {}, {}
    local stored = G_reader_settings:readSetting(KEY)
    for _,rel in ipairs(type(stored)=="table" and stored or {}) do
        if valid(rel) and not seen[rel] and lfs.attributes(Library.abs(rel),"mode")=="file" then
            seen[rel]=true
            if rel~=exclude then
                list[#list+1]=rel
                if #list==LIMIT then break end
            end
        end
    end
    return list
end
function Recents.remember(path)
    if type(path)~="string" then return end
    local rel=Library.relOf(path)
    if not valid(rel) then return end
    local list={rel}
    for _,item in ipairs(Recents.list(rel)) do if #list<LIMIT then list[#list+1]=item end end
    G_reader_settings:saveSetting(KEY,list)
end
return Recents
