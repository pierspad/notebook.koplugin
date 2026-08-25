--[[--
Translations for this plugin's own strings.

KOReader's gettext serves one catalogue -- the application's own -- and a plugin
that is not part of the KOReader tree has no strings in it. Every label here
would therefore stay in English whatever language the device is set to, which is
what happened.

So this loads a catalogue of our own from `locale/<language>.po`, falling back to
the language without its region (`it` for `it_IT`) and then to English, which is
what the source strings already are. A language with no file is not an error: it
reads in English, exactly as before.

Adding a language means adding one file to `locale/`. Nothing here needs to
change, and nothing needs to be registered.

@module notebook.i18n
--]]--

local logger = require("logger")

local catalogue = {}

--[[--
Reads a .po file into a lookup table.

A deliberately small parser rather than a general one: it handles msgid, msgstr
and the continuation lines that follow either, which is all our own catalogues
contain. Plural forms and contexts are not used here, and entries carrying them
are skipped rather than half-understood.
--]]
local function parsePO(path)
    local file = io.open(path, "r")
    if not file then return nil end

    local entries = {}
    local id, str, target
    local fuzzy, has_context = false, false
    -- Flags read from the comment lines that come *before* the entry they
    -- describe, and therefore before the msgid that closes the previous one.
    -- Held separately, or flushing the previous entry would clear them.
    local next_fuzzy = false

    local function flush()
        if id and id ~= "" and str and str ~= "" and not fuzzy and not has_context then
            entries[id] = str
        end
        id, str, target = nil, nil, nil
        fuzzy, has_context = false, false
    end

    local function unquote(line)
        return line:match('^%s*"(.*)"%s*$')
    end

    for line in file:lines() do
        if line:match("^%s*#, .*fuzzy") then
            next_fuzzy = true
        elseif line:match("^msgctxt") then
            has_context = true
        elseif line:match("^msgid_plural") then
            has_context = true
        elseif line:match("^msgid ") then
            flush()
            fuzzy, next_fuzzy = next_fuzzy, false
            id = unquote(line:sub(7)) or ""
            target = "id"
        elseif line:match("^msgstr ") then
            str = unquote(line:sub(8)) or ""
            target = "str"
        elseif line:match('^%s*"') then
            local more = unquote(line)
            if more then
                if target == "id" then
                    id = (id or "") .. more
                elseif target == "str" then
                    str = (str or "") .. more
                end
            end
        elseif line:match("^%s*$") then
            flush()
        end
    end
    flush()
    file:close()

    -- Escapes, which .po files carry in the same form Lua does.
    local decoded = {}
    for key, value in pairs(entries) do
        decoded[key:gsub("\\n", "\n"):gsub('\\"', '"'):gsub("\\\\", "\\")] =
            value:gsub("\\n", "\n"):gsub('\\"', '"'):gsub("\\\\", "\\")
    end
    return decoded
end

--- The language KOReader is running in, e.g. "it_IT".
local function currentLanguage()
    local ok, setting = pcall(function()
        return G_reader_settings and G_reader_settings:readSetting("language")
    end)
    if ok and type(setting) == "string" and setting ~= "" then return setting end
    return os.getenv("LANGUAGE") or os.getenv("LANG") or "en"
end

--- Where this file lives, which is where the catalogues live too.
local function localeDir()
    local this = debug.getinfo(1, "S").source:match("^@(.*)$")
    local dir = this and this:match("^(.*)/[^/]+$")
    return dir and (dir .. "/locale") or nil
end

local function load()
    local dir = localeDir()
    if not dir then return end

    local language = currentLanguage():gsub("[.:].*$", "")
    local candidates = { language }
    local base = language:match("^(%a+)")
    if base and base ~= language then table.insert(candidates, base) end

    for _, name in ipairs(candidates) do
        local entries = parsePO(dir .. "/" .. name .. ".po")
        if entries then
            catalogue = entries
            logger.dbg("Notebook: loaded translations for", name)
            return
        end
    end
end

local ok, err = pcall(load)
if not ok then
    -- A catalogue that cannot be read must never stop the plugin loading: the
    -- worst it can cost is English.
    logger.warn("Notebook: could not load translations:", err)
end

--- The catalogue reader, exposed so the shipped catalogues can be checked.
local Text = { parse = parsePO }

return setmetatable(Text, {
    __call = function(_, text)
        return catalogue[text] or text
    end,
})
