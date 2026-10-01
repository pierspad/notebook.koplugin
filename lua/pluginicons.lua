-- Startup icon synchronization, independent of dispatcher and notebook lifecycle.
local DataStorage=require("datastorage")
local lfs=require("libs/libkoreader-lfs")
local logger=require("logger")
local function installIcons()
    -- Finding our own directory needs care. KOReader runs with its working
    -- directory somewhere else entirely (/var/tmp/root on Kindle), so a relative
    -- path resolves to nothing, and the failure is silent: the toolbar just
    -- fills up with "icon not found" placeholders.
    --
    -- Try the path Lua recorded for this file, then the conventional location
    -- under the data directory, and use whichever actually contains the icons.
    local this_file = debug.getinfo(1, "S").source:match("^@(.*)$")
    local candidates = {
        this_file and this_file:match("^(.*)/[^/]+$") or nil,
        DataStorage:getDataDir() .. "/plugins/notebook.koplugin",
    }

    local src
    for _, dir in ipairs(candidates) do
        if lfs.attributes(dir .. "/icons", "mode") == "directory" then
            src = dir .. "/icons"
            break
        end
    end
    if not src then
        logger.warn("Notebook: could not locate the icon directory; tried",
            table.concat(candidates, ", "))
        return
    end

    local dst = DataStorage:getDataDir() .. "/icons"

    if lfs.attributes(dst, "mode") ~= "directory" then
        if not lfs.mkdir(dst) then
            logger.warn("Notebook: cannot create icon directory", dst)
            return
        end
    end

    for name in lfs.dir(src) do
        if name:match("%.svg$") then
            local from = io.open(src .. "/" .. name, "rb")
            if from then
                local data = from:read("*a")
                from:close()
                local existing = io.open(dst .. "/" .. name, "rb")
                local unchanged = existing and existing:read("*a") == data
                if existing then existing:close() end
                local to = not unchanged and io.open(dst .. "/" .. name, "wb")
                if to then
                    to:write(data)
                    to:close()
                elseif not unchanged then
                    logger.warn("Notebook: cannot write icon", name)
                end
            end
        end
    end
end

return installIcons
