-- A private require cache prevents collisions with old Scribe and other plugins
-- using generic names such as canvas, document, settings and i18n. Each chunk
-- retains this require in its environment, including callbacks loaded later.
return function(directory)
    local shared_require = require
    local cache = {}
    local own = {}
    for name in ("actionmenu canvas document export gallery i18n lassomenu lasso launcherbar library " ..
        "newnotebook notebook pagepanel papersample pdfbackground pressure rect renderer safe settings shape share stroke textobject xopp " ..
        "template templatepicker thumbnail tuning tuningdock widgets"):gmatch("%S+") do own[name] = true end
    local function privateRequire(name)
        if not own[name] then return shared_require(name) end
        if cache[name] ~= nil then return cache[name] end
        local chunk = assert(loadfile(directory .. "/" .. name .. ".lua"))
        setfenv(chunk, setmetatable({require=privateRequire}, {__index=_G}))
        local result = chunk(name)
        cache[name] = result == nil and true or result
        return cache[name]
    end
    return privateRequire
end
