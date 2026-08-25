#!/usr/bin/env luajit
--[[--
Tests for what happens to an install that predates the plugin's own name.

This plugin was `scribe.koplugin` before it had a repository, and KOReader takes
a plugin's name from its directory: renaming the directory renames the plugin,
and everything keyed on that name -- where the notebooks are kept, what the
settings are called, which plugin a launcher tab says it opens -- points at a
name nothing answers to any more.

None of that can be checked by opening the plugin and looking, because it only
goes wrong on a device that has the old state on it. So it is checked here,
where both worlds can be built on demand.

Run with:  luajit spec/migration.lua   (from the plugin directory)
--]]--

package.path = "./?.lua;./spec/?.lua;" .. package.path

local support = require("support")
local uistubs = require("uistubs")

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

--- A fresh Library over a filesystem holding whichever roots are named.
local function libraryWith(roots)
    for _, name in ipairs{ "library", "thumbnail" } do
        package.loaded[name] = nil
    end
    local fs = { ["/data"] = { mode = "directory", modification = 0 } }
    for _, root in ipairs(roots) do
        fs["/data/" .. root] = { mode = "directory", modification = 0 }
    end
    support.installStubs()
    uistubs.install(fs)
    -- The widget stubs stand in a recording thumbnail module, which is what the
    -- gallery tests want and not what these do: cleared afterwards so that a
    -- require here loads the real one.
    package.loaded["thumbnail"] = nil
    return require("library"), fs
end

io.write("where the notebooks are kept\n")

test("a fresh install keeps them under the plugin's own name", function()
    local Library = libraryWith{}
    assertEq(Library.root(), "/data/notebook", "root of a fresh install")
end)

test("an install that predates the rename keeps using the folder it has", function()
    -- The one that matters. Moving it would be the obvious thing and the wrong
    -- one: it is a directory full of somebody's handwriting, and a move that
    -- fails halfway is far worse than a folder with a dated name.
    local Library = libraryWith{ "scribe" }
    assertEq(Library.root(), "/data/scribe", "root when only the old folder exists")
end)

test("with both there, the new one wins and the old is left alone", function()
    local Library, fs = libraryWith{ "scribe", "notebook" }
    assertEq(Library.root(), "/data/notebook", "root when both exist")
    assertTrue(fs["/data/scribe"] ~= nil, "the old folder was disturbed")
end)

io.write("thumbnails\n")

test("the cache key is the same wherever the root is", function()
    -- Keyed on the path below the root rather than on the whole path, so that
    -- the pictures already drawn are still found after the root changes name.
    local Library = libraryWith{ "scribe" }
    local Thumbnail = require("thumbnail")

    local old_key = Thumbnail.pathFor(Library.root() .. "/Trip/day one.scribe")

    local Library2 = libraryWith{ "notebook" }
    local Thumbnail2 = require("thumbnail")
    local new_key = Thumbnail2.pathFor(Library2.root() .. "/Trip/day one.scribe")

    assertEq(old_key:match("[^/]+$"), new_key:match("[^/]+$"),
        "the same notebook cached under two different names")
end)

io.write("the launcher tab\n")

test("a tab recorded under either name still opens the notebooks", function()
    for _, key in ipairs{ "notebook", "scribe" } do
        package.loaded["launcherbar"] = nil
        package.loaded["infra/sui_store"] = {
            get = function(_, k)
                if k == "simpleui_qa_list" then return { "custom_qa_1" } end
                if k == "simpleui_qa_custom_qa_1" then return { plugin_key = key } end
            end,
        }
        support.installStubs()
        uistubs.install({})
        local marked
        package.loaded["screens/sui_bottombar"] = {
            setTempTabActive = function(_, id, active) if active then marked = id end end,
        }

        local LauncherBar = require("launcherbar")
        LauncherBar.markActive({}, { active_action = "custom_qa_1" })
        assertEq(marked, "custom_qa_1", "a tab recorded as plugin_key=" .. key)
    end
end)

test("a tab pointing at neither is not ours to mark", function()
    package.loaded["launcherbar"] = nil
    package.loaded["infra/sui_store"] = {
        get = function(_, k)
            if k == "simpleui_qa_list" then return { "custom_qa_1" } end
            if k == "simpleui_qa_custom_qa_1" then return { plugin_key = "calibre" } end
        end,
    }
    support.installStubs()
    uistubs.install({})
    local marked = false
    package.loaded["screens/sui_bottombar"] = {
        setTempTabActive = function() marked = true end,
    }

    local LauncherBar = require("launcherbar")
    LauncherBar.markActive({}, { active_action = "custom_qa_1" })
    assertTrue(not marked, "marked a tab belonging to another plugin")
end)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
