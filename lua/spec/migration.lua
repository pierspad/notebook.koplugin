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
local function libraryWith(roots, opts)
    for _, name in ipairs{ "library", "thumbnail" } do
        package.loaded[name] = nil
    end
    local fs = { ["/data"] = { mode = "directory", modification = 0 } }
    for _, root in ipairs(roots) do
        fs["/data/" .. root] = { mode = "directory", modification = 0 }
        fs["/data/" .. root .. "/note.scribe"] = { mode = "file", modification = 1, size = 10 }
    end
    support.installStubs()
    local rec = uistubs.install(fs)
    rec.rename_fails = opts and opts.rename_fails or false
    -- The widget stubs stand in a recording thumbnail module, which is what the
    -- gallery tests want and not what these do: cleared afterwards so that a
    -- require here loads the real one.
    package.loaded["thumbnail"] = nil
    return require("library"), fs, rec
end

io.write("where the notebooks are kept\n")

test("a fresh install keeps them under the plugin's own name", function()
    local Library = libraryWith{}
    assertEq(Library.root(), "/data/notebook", "root of a fresh install")
end)

test("an install that predates the rename has its folder moved across", function()
    local Library, fs = libraryWith{ "scribe" }
    assertEq(Library.root(), "/data/notebook", "root after the move")
    assertTrue(fs["/data/notebook"] ~= nil, "the folder is not at the new name")
    assertTrue(fs["/data/scribe"] == nil, "the old folder is still there")
end)

test("the notebooks inside come with it", function()
    -- The move is a rename of the directory, so this is really a check that it
    -- was one operation and not a folder created empty beside the old one.
    local Library, fs = libraryWith{ "scribe" }
    Library.root()
    assertTrue(fs["/data/notebook/note.scribe"] ~= nil, "the notebook was left behind")
end)

test("a move that cannot be made leaves the notebooks reachable", function()
    -- A read-only filesystem, a permission that is not there, a leftover at the
    -- destination. Tidying up a name is not worth failing to open on.
    local Library, fs = libraryWith({ "scribe" }, { rename_fails = true })
    assertEq(Library.root(), "/data/scribe", "root when the move is refused")
    assertTrue(fs["/data/scribe/note.scribe"] ~= nil, "the notebook went missing")
end)

test("with both there, the new one is used and the old is left alone", function()
    -- Not merged, and not overwritten: two folders means something unexpected
    -- happened, and a plugin's response to that should not be to move files.
    local Library, fs = libraryWith{ "scribe", "notebook" }
    assertEq(Library.root(), "/data/notebook", "root when both exist")
    assertTrue(fs["/data/scribe/note.scribe"] ~= nil, "the old folder was disturbed")
end)

test("the answer is worked out once, not on every listing", function()
    local Library, fs = libraryWith{ "scribe" }
    assertEq(Library.root(), "/data/notebook", "first answer")
    -- Something else creates the old name again; the plugin has already moved.
    fs["/data/scribe"] = { mode = "directory", modification = 0 }
    assertEq(Library.root(), "/data/notebook", "second answer")
end)

io.write("thumbnails\n")

test("the cache key is the same wherever the root is", function()
    -- Keyed on the path below the root rather than on the whole path, so the
    -- pictures already drawn are still found once the folder has moved -- and
    -- so a move that was refused does not invalidate them either.
    local Library, _, rec = libraryWith({ "scribe" }, { rename_fails = true })
    local Thumbnail = require("thumbnail")
    local refused = Thumbnail.pathFor(Library.root() .. "/Trip/day one.scribe")
    rec.restoreRename()

    local Library2 = libraryWith{ "scribe" }
    local Thumbnail2 = require("thumbnail")
    local moved = Thumbnail2.pathFor(Library2.root() .. "/Trip/day one.scribe")

    assertEq(refused:match("[^/]+$"), moved:match("[^/]+$"),
        "the same notebook cached under two different names")
end)

io.write("the stored settings\n")

--- A settings store holding whatever is given, recording what happens to it.
local function storeWith(values)
    local kept = {}
    for k, v in pairs(values) do kept[k] = v end
    return {
        kept = kept,
        readSetting = function(self, k) return self.kept[k] end,
        saveSetting = function(self, k, v) self.kept[k] = v end,
        delSetting = function(self, k) self.kept[k] = nil end,
    }
end

test("settings written under the old name are moved onto the new one", function()
    local Library = libraryWith{}
    local store = storeWith{ scribe_pen_width = 7, scribe_eraser_mode = "area" }

    Library.migrateSettings(store)

    assertEq(store.kept.notebook_pen_width, 7, "pen width")
    assertEq(store.kept.notebook_eraser_mode, "area", "eraser mode")
    assertTrue(store.kept.scribe_pen_width == nil,
        "the old key is still in the settings file")
end)

test("a setting already at the new name is not overwritten by a stale one", function()
    local Library = libraryWith{}
    local store = storeWith{ scribe_pen_width = 7, notebook_pen_width = 3 }

    Library.migrateSettings(store)

    assertEq(store.kept.notebook_pen_width, 3, "the value in use")
    assertTrue(store.kept.scribe_pen_width == nil, "the stale key was kept")
end)

test("moving twice is the same as moving once", function()
    local Library = libraryWith{}
    local store = storeWith{ scribe_order = "name" }

    Library.migrateSettings(store)
    store:saveSetting("notebook_order", "recent")
    Library.migrateSettings(store)

    assertEq(store.kept.notebook_order, "recent",
        "the second run put the old value back")
end)

test("a false setting moves across like any other", function()
    -- `if value then` would drop this one, and drawing with a finger is exactly
    -- the setting somebody turns off and expects to stay off.
    local Library = libraryWith{}
    local store = storeWith{ scribe_draw_with_finger = false }

    Library.migrateSettings(store)

    assertEq(store.kept.notebook_draw_with_finger, false, "draw with finger")
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
