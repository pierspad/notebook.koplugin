#!/usr/bin/env luajit
--[[--
Tests for the plugin's own translations.

Two things matter here. The catalogue reader has to understand the files we
ship, including the parts of the .po format they actually use. And the shipped
catalogues have to keep up with the strings in the source -- a translation that
silently falls back to English for half the plugin is worse than no translation,
because nothing announces it.

Run with:  luajit spec/i18n.lua   (from the plugin directory)
--]]--

package.path = "./?.lua;./spec/?.lua;" .. package.path

local support = require("support")
support.installStubs()
package.loaded["i18n"] = nil
G_reader_settings={readSetting=function(_,key) return key=="language" and "en" or nil end}

local Text = require("i18n")

local passed, failed = 0, 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        io.write("  ok   ", name, "\n")
    else
        failed = failed + 1
        io.write("  FAIL ", name, "\n         ", tostring(err), "\n")
    end
end

local function assertEq(got, want, what)
    if got ~= want then
        error(string.format("%s: got %s, want %s", what or "value",
            tostring(got), tostring(want)), 2)
    end
end

local function assertTrue(v, what)
    if not v then error((what or "value") .. ": expected truthy, got " .. tostring(v), 2) end
end

local function writeTemp(body)
    local path = os.tmpname()
    local file = assert(io.open(path, "w"))
    file:write(body)
    file:close()
    return path
end

io.write("catalogue reader\n")

test("plain entries are read", function()
    local path = writeTemp('msgid "Open"\nmsgstr "Apri"\n')
    local entries = Text.parse(path)
    os.remove(path)
    assertEq(entries["Open"], "Apri", "translation")
end)

test("continuation lines are joined", function()
    local path = writeTemp('msgid ""\n"Delete this?"\nmsgstr ""\n"Eliminare questo?"\n')
    local entries = Text.parse(path)
    os.remove(path)
    assertEq(entries["Delete this?"], "Eliminare questo?", "translation")
end)

test("escapes come out as the characters they stand for", function()
    local path = writeTemp('msgid "a\\nb"\nmsgstr "c\\nd"\n')
    local entries = Text.parse(path)
    os.remove(path)
    assertEq(entries["a\nb"], "c\nd", "translation")
end)

test("an untranslated entry is not an entry", function()
    local path = writeTemp('msgid "Open"\nmsgstr ""\n')
    local entries = Text.parse(path)
    os.remove(path)
    assertTrue(entries["Open"] == nil, "an empty translation was stored")
end)

test("a fuzzy entry is left to the source string", function()
    local path = writeTemp('#, fuzzy\nmsgid "Open"\nmsgstr "Boh"\n')
    local entries = Text.parse(path)
    os.remove(path)
    assertTrue(entries["Open"] == nil, "a fuzzy translation was used")
end)

test("a missing catalogue is nothing, not an error", function()
    assertTrue(Text.parse("/nowhere/xx.po") == nil, "expected nil")
end)

test("a string with no translation falls back to itself", function()
    assertEq(Text("Definitely not in any catalogue"),
        "Definitely not in any catalogue", "fallback")
end)

io.write("shipped catalogues\n")

--- Every string the plugin passes through the translator.
local function sourceStrings()
    local found, order = {}, {}
    local pipe = io.popen("ls *.lua")
    for name in pipe:lines() do
        if name ~= "i18n.lua" and name ~= "_meta.lua" then
            local file = assert(io.open(name, "r"))
            local body = file:read("*a")
            file:close()
            for text in body:gmatch('_%("([^"]*)"%)') do
                if not found[text] then
                    found[text] = true
                    table.insert(order, text)
                end
            end
        end
    end
    pipe:close()
    return order
end

-- Guard the widget fields that most commonly put prose on screen. Symbols,
-- counters and empty placeholders are controls rather than translatable text.
-- Everything else must be passed through i18n instead of silently remaining
-- English in every catalogue.
local function hardcodedWidgetStrings()
    local offenders = {}
    local control_glyphs = {
        ["Aa"] = true, ["B"] = true, ["I"] = true, ["U̲"] = true,
        ["A−"] = true, ["A+"] = true,
    }
    local pipe = io.popen("ls *.lua")
    for name in pipe:lines() do
        local file = assert(io.open(name, "r"))
        local line_no = 0
        for line in file:lines() do
            line_no = line_no + 1
            for _, field in ipairs({ "text", "title", "section", "label" }) do
                local value = line:match('%f[%a]' .. field .. '%s*=%s*"([^"\\]*)"')
                if value and value ~= "" and value:find("%a") then
                    -- Fixed-width page-count sample: layout data, never displayed.
                    if value ~= "  888 / 888  " and not control_glyphs[value] then
                        table.insert(offenders, string.format("%s:%d: %s = %q",
                            name, line_no, field, value))
                    end
                end
            end
        end
        file:close()
    end
    pipe:close()
    return offenders
end

--[[--
The shipped catalogues, if any.

A build with no catalogue at all is a legitimate one -- the plugin reads in
English -- so there is nothing to check rather than something to fail.
--]]
local template_ids=Text.ids("locale/notebook.pot")

test("every interface string is valid in English fallback", function()
    for _,text in ipairs(sourceStrings()) do
        local key=text:gsub("\\n","\n")
        assertEq(Text(key),key,"English: "..text)
    end
end)

test("visible widget prose is never hardcoded", function()
    local offenders = hardcodedWidgetStrings()
    assertEq(#offenders, 0, "hardcoded: " .. table.concat(offenders, " | "))
end)

test("the contributor template covers every string in the source", function()
    local source={}
    for _,text in ipairs(sourceStrings()) do source[text:gsub("\\n","\n")]=true end
    local missing,stale={},{}
    for text in pairs(source) do if not template_ids[text] then table.insert(missing,text) end end
    for text in pairs(template_ids) do if not source[text] then table.insert(stale,text) end end
    assertEq(#missing,0,"missing from template: "..table.concat(missing," | "))
    assertEq(#stale,0,"stale in template: "..table.concat(stale," | "))
end)

local catalogues={}
local listed=io.popen("ls locale/*.po 2>/dev/null")
for path in listed:lines() do table.insert(catalogues,path) end
listed:close()

test("every shipped language translates every template entry", function()
    local missing = {}
    for _,path in ipairs(catalogues) do
        local entries=Text.parse(path)
        for text in pairs(template_ids) do
            if not entries[text] then table.insert(missing,path..": "..text:gsub("\n","\\n")) end
        end
    end
    assertEq(#missing, 0, "untranslated: " .. table.concat(missing, " | "))
end)

test("no shipped language contains obsolete entries", function()
    local stale = {}
    for _,path in ipairs(catalogues) do
        for key in pairs(Text.ids(path)) do
            if not template_ids[key] then table.insert(stale,path..": "..key:gsub("\n","\\n")) end
        end
    end
    assertEq(#stale, 0, "no longer used: " .. table.concat(stale, " | "))
end)

test("translations preserve numbered substitution fields", function()
    local broken={}
    local function fields(text)
        local out={}
        for field in text:gmatch("%%[0-9]+") do out[field]=(out[field] or 0)+1 end
        return out
    end
    local function same(a,b)
        for key,value in pairs(a) do if b[key]~=value then return false end end
        for key,value in pairs(b) do if a[key]~=value then return false end end
        return true
    end
    for _,path in ipairs(catalogues) do
        for id,value in pairs(Text.parse(path)) do
            if not same(fields(id),fields(value)) then
                table.insert(broken,path..": "..id:gsub("\n","\\n"))
            end
        end
    end
    assertEq(#broken,0,"changed substitution fields: "..table.concat(broken," | "))
end)

test("KOReader language settings activate every shipped catalogue", function()
    local original=G_reader_settings
    for _,path in ipairs(catalogues) do
        local language=path:match("/([^/]+)%.po$")
        local entries=Text.parse(path)
        G_reader_settings={readSetting=function(_,key)
            return key=="language" and language or nil
        end}
        package.loaded["i18n"]=nil
        local localized=require("i18n")
        for id,value in pairs(entries) do
            assertEq(localized(id),value,language..": "..id)
        end
    end
    -- These are real variants from KOReader's language menu. They deliberately
    -- share a base catalogue instead of duplicating 132 strings per region.
    local aliases={it_IT="it",pt_PT="pt",pl_PL="pl",["zh_TW.Big5"]="zh_TW"}
    for setting,catalogue_name in pairs(aliases) do
        G_reader_settings={readSetting=function(_,key)
            return key=="language" and setting or nil
        end}
        package.loaded["i18n"]=nil
        local regional=require("i18n")
        local expected=Text.parse("locale/"..catalogue_name..".po")
        assertEq(regional("New notebook"),expected["New notebook"],
            setting.." regional language fallback")
    end
    G_reader_settings=original
    package.loaded["i18n"]=nil
end)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
