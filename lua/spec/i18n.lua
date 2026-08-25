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

--[[--
The shipped catalogues, if any.

A build with no catalogue at all is a legitimate one -- the plugin reads in
English -- so there is nothing to check rather than something to fail.
--]]
local italian = Text.parse("locale/it.po")

test("the Italian catalogue covers every string in the source", function()
    if not italian then return end
    local entries = italian

    local missing = {}
    for _, text in ipairs(sourceStrings()) do
        -- The source carries \n as an escape; the catalogue reader has already
        -- turned its own into real newlines, so compare like for like.
        local key = text:gsub("\\n", "\n")
        if not entries[key] then table.insert(missing, text) end
    end

    assertEq(#missing, 0, "untranslated: " .. table.concat(missing, " | "))
end)

test("the catalogue has nothing the source no longer says", function()
    if not italian then return end
    local entries = italian
    local live = {}
    for _, text in ipairs(sourceStrings()) do
        live[text:gsub("\\n", "\n")] = true
    end

    local stale = {}
    for key in pairs(entries) do
        if not live[key] then table.insert(stale, (key:gsub("\n", "\\n"))) end
    end
    assertEq(#stale, 0, "no longer used: " .. table.concat(stale, " | "))
end)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
