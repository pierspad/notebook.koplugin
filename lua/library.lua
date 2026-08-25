--[[--
Notebook storage: the files and folders on disk, and the operations on them.

Kept free of any widget so that creating, renaming and deleting can be tested
without a screen, and so the gallery stays a thin layer over it.

A notebook is `<name>.scribe`; the file name *is* the notebook's name. That is
what makes renaming a rename, and keeps the folder comprehensible when it is
reached over USB rather than through the app. Folders are ordinary directories,
for the same reason: what you see on the device is what you see on the computer.

Paths handed in and out are relative to the notebook root, never absolute, so a
caller cannot walk out of it by accident.

@module notebook.library
--]]--

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local EXT = ".scribe"

local Library = {}

--[[--
Where the notebooks live, and the one-time move that gets them there.

`koreader/notebook`. Early builds of this plugin kept them under another name;
where that folder is found and the current one is not, it is moved across the
first time the notebooks are asked for, so that there is one place for this and
not two forever.

The move is a single `os.rename` of the directory, which within a filesystem is
one atomic operation: either the folder is at the new name or it is at the old
one, never half at each. That is the whole reason it is done this way rather
than by copying the notebooks across one at a time, which is the version that
can be interrupted with somebody's handwriting in two places.

If the rename fails anyway -- the destination existing already, a permission
that is not there, the two paths somehow on different filesystems -- the old
folder is used exactly where it is. Tidying up a name is not worth failing to
open on.

Worked out once and remembered, because this is asked on every listing and the
answer cannot change while the plugin is running.
--]]
local ROOT_NAME = "notebook"
local LEGACY_ROOT_NAME = "scribe"

local root_path = nil

function Library.root()
    if root_path then return root_path end

    local data = DataStorage:getDataDir()
    local root = data .. "/" .. ROOT_NAME
    local legacy = data .. "/" .. LEGACY_ROOT_NAME

    if lfs.attributes(root, "mode") ~= "directory"
        and lfs.attributes(legacy, "mode") == "directory" then
        if os.rename(legacy, root) then
            logger.info("Notebook: moved", legacy, "to", root)
        else
            logger.warn("Notebook: could not move", legacy, "to", root,
                "-- continuing to use", legacy)
            root = legacy
        end
    end

    root_path = root
    return root_path
end

--- Forgets the resolved root. For tests, which build several filesystems.
function Library.resetRoot()
    root_path = nil
end

--[[--
Moves the stored settings onto the keys this plugin now uses.

Everything KOReader keeps for a plugin is keyed by a prefix, and early builds
used a different one. Read-with-a-fallback would have worked and would have left
the old keys in the settings file forever, which is the kind of thing that is
still there in three years and that nobody dares delete because nobody remembers
what reads it.

So they are moved once and the old ones deleted. Idempotent: a key that is not
there is not moved, and a key already at the new name is not overwritten by a
stale one left beside it.
--]]
local SETTING_PREFIX = "notebook_"
local LEGACY_SETTING_PREFIX = "scribe_"

local SETTINGS = {
    "pen_width", "highlighter_width", "eraser_size", "eraser_mode",
    "draw_with_finger", "order",
}

function Library.migrateSettings(store)
    store = store or G_reader_settings
    if not store then return end

    for _, key in ipairs(SETTINGS) do
        local old = LEGACY_SETTING_PREFIX .. key
        local value = store:readSetting(old)
        if value ~= nil then
            if store:readSetting(SETTING_PREFIX .. key) == nil then
                store:saveSetting(SETTING_PREFIX .. key, value)
            end
            store:delSetting(old)
        end
    end
end

--- Absolute path for a location relative to the notebook root.
function Library.abs(rel)
    if not rel or rel == "" then return Library.root() end
    return Library.root() .. "/" .. rel
end

--- Creates a directory, and any parent it needs.
function Library.ensureDir(rel)
    local path = Library.abs(rel)
    if lfs.attributes(path, "mode") == "directory" then return true end

    -- Build the path a level at a time; mkdir does not create parents.
    local acc = Library.root()
    if lfs.attributes(acc, "mode") ~= "directory" and not lfs.mkdir(acc) then
        logger.err("Notebook: cannot create", acc)
        return false
    end
    for part in (rel or ""):gmatch("[^/]+") do
        acc = acc .. "/" .. part
        if lfs.attributes(acc, "mode") ~= "directory" and not lfs.mkdir(acc) then
            logger.err("Notebook: cannot create", acc)
            return false
        end
    end
    return true
end

--- Path of a notebook, given its folder and name.
function Library.pathFor(name, folder)
    return Library.abs(folder) .. "/" .. name .. EXT
end

function Library.exists(name, folder)
    return lfs.attributes(Library.pathFor(name, folder), "mode") == "file"
end

--[[--
Rejects names that cannot be used as a file name.

Since the name is the file name, a stray slash would silently write outside the
notebook folder, so this is a safety check and not only a tidiness one.
Returns true, or false plus a reason to show the reader.
--]]
function Library.validateName(name)
    if not name or name:match("^%s*$") then
        return false, "empty"
    end
    if name:find("/") or name:find("\\") then
        return false, "slash"
    end
    if name == "." or name == ".." then
        return false, "reserved"
    end
    if #name > 100 then
        return false, "too_long"
    end
    return true
end

--- Returns a name close to `name` that is not taken yet in `folder`.
function Library.uniqueName(name, folder)
    if not Library.exists(name, folder) then return name end
    for i = 2, 999 do
        local candidate = string.format("%s (%d)", name, i)
        if not Library.exists(candidate, folder) then return candidate end
    end
    return name .. " " .. tostring(os.time())
end

--[[--
The ways a folder can be ordered, and what each is called.

Kept here rather than in the gallery because the ordering is a property of the
listing, not of the screen showing it -- and because a comparison that sorts
folders one way and notebooks another would be a bug that only shows up in a
folder holding both. What each one is *called* belongs to the screen, and is in
gallery.lua.

Every one of them settles ties by name. Two notebooks written in the same second
are common -- a duplicate, or a batch export -- and a sort with no tie-breaker
puts them in whatever order the filesystem happened to hand them over, which
changes between listings and makes the grid appear to shuffle itself.
--]]
Library.DEFAULT_ORDER = "recent"

Library.ORDERS = {
    recent = {
        compare = function(a, b)
            if a.modified == b.modified then return a.name < b.name end
            return a.modified > b.modified
        end,
    },
    oldest = {
        compare = function(a, b)
            if a.modified == b.modified then return a.name < b.name end
            return a.modified < b.modified
        end,
    },
    name = {
        compare = function(a, b) return a.name:lower() < b.name:lower() end,
    },
    name_desc = {
        compare = function(a, b) return a.name:lower() > b.name:lower() end,
    },
}

--- The orders, in the sequence they should be offered.
Library.ORDER_SEQUENCE = { "recent", "oldest", "name", "name_desc" }

--[[--
Lists one folder: its subfolders first, then its notebooks and exported PDFs.

Folders lead because they are containers -- burying them among the notebooks
makes a folder easy to miss. Within each group, `sort` decides the order; see
Library.ORDERS.
--]]
function Library.list(folder, sort)
    Library.ensureDir(folder)
    local dir = Library.abs(folder)
    local folders, files = {}, {}

    for entry in lfs.dir(dir) do
        -- Skip . and .., and anything hidden -- the thumbnail cache lives in a
        -- dotted folder precisely so it does not show up here.
        if entry:sub(1, 1) ~= "." then
            local path = dir .. "/" .. entry
            local attr = lfs.attributes(path)
            --[[
            KOReader keeps a document's bookmarks, last page and settings in a
            sidecar directory named after it, `<name>.sdr`, created the moment
            the document is opened. Ours are created by opening an exported PDF
            from here, so they appear in the same folder as the export -- and
            shown as folder cards they are worse than clutter: they are cards
            that look like somewhere to go and lead into an empty grid.

            Hidden rather than moved or suppressed at the source. They are
            KOReader's, they hold the reading position of a PDF that is still
            perfectly openable, and a plugin that deleted them would be throwing
            away state that is not its own.
            --]]
            if attr and attr.mode == "directory" and entry:match("%.sdr$") then
                attr = nil
            end
            if attr and attr.mode == "directory" then
                table.insert(folders, {
                    name = entry,
                    path = path,
                    rel = folder and folder ~= "" and (folder .. "/" .. entry) or entry,
                    is_folder = true,
                    modified = attr.modification or 0,
                })
            elseif attr and attr.mode == "file" then
                local name = entry:match("^(.+)%" .. EXT .. "$")
                local pdf_name = not name and entry:match("^(.+)%.pdf$") or nil
                if name or pdf_name then
                    table.insert(files, {
                        name = name or pdf_name,
                        path = path,
                        folder = folder,
                        is_pdf = pdf_name ~= nil,
                        modified = attr.modification or 0,
                        size = attr.size or 0,
                    })
                end
            end
        end
    end

    local order = Library.ORDERS[sort] or Library.ORDERS[Library.DEFAULT_ORDER]
    table.sort(folders, order.compare)
    table.sort(files, order.compare)

    local items = {}
    for _, f in ipairs(folders) do table.insert(items, f) end
    for _, f in ipairs(files) do table.insert(items, f) end
    return items
end

--- The folder containing `rel`, or "" if it is already at the root.
function Library.parentOf(rel)
    if not rel or rel == "" then return nil end
    return rel:match("^(.*)/[^/]+$") or ""
end

local function copyFile(from, to)
    local src = io.open(from, "rb")
    if not src then return false end
    local data = src:read("*a")
    src:close()

    local dst = io.open(to, "wb")
    if not dst then return false end
    dst:write(data)
    dst:close()
    return true
end

--- Copies a file, by absolute paths. Public because sending stages copies.
Library.copyFile = copyFile

function Library.createFolder(name, parent)
    local ok, reason = Library.validateName(name)
    if not ok then return false, reason end

    local rel = parent and parent ~= "" and (parent .. "/" .. name) or name
    if lfs.attributes(Library.abs(rel), "mode") then return false, "exists" end
    if not Library.ensureDir(rel) then return false, "failed" end
    return true
end

function Library.rename(old_name, new_name, folder)
    local ok, reason = Library.validateName(new_name)
    if not ok then return false, reason end
    if new_name == old_name then return true end
    if Library.exists(new_name, folder) then return false, "exists" end
    if not os.rename(Library.pathFor(old_name, folder),
                     Library.pathFor(new_name, folder)) then
        return false, "failed"
    end
    return true
end

--- Renames a folder in place.
function Library.renameFolder(rel, new_name)
    local ok, reason = Library.validateName(new_name)
    if not ok then return false, reason end

    local parent = Library.parentOf(rel) or ""
    local target = parent ~= "" and (parent .. "/" .. new_name) or new_name
    if lfs.attributes(Library.abs(target), "mode") then return false, "exists" end
    if not os.rename(Library.abs(rel), Library.abs(target)) then
        return false, "failed"
    end
    return true
end

function Library.duplicate(name, folder)
    local copy = Library.uniqueName(name .. " copy", folder)
    if not copyFile(Library.pathFor(name, folder),
                    Library.pathFor(copy, folder)) then
        return nil
    end
    return copy
end

function Library.delete(name, folder)
    return os.remove(Library.pathFor(name, folder)) and true or false
end

--[[--
Deletes any single file, by absolute path.

A document's sidecar directory goes with it. Hiding those from the grid means
that a sidecar left behind by a deleted export would be invisible *and*
permanent: nothing in this plugin would ever show it again, and nothing would
ever clean it up. Removing it here keeps the two facts consistent -- if you
cannot see it, it is because there is nothing left for it to belong to.
--]]
function Library.deletePath(path)
    local gone = os.remove(path) and true or false
    if gone then
        local sidecar = path:gsub("%.[^./]+$", "") .. ".sdr"
        if lfs.attributes(sidecar, "mode") == "directory" then
            Library.deleteTree(sidecar)
        end
    end
    return gone
end

--[[--
Deletes a directory and everything under it, by absolute path.

Recursive, because a folder the reader wants gone is rarely empty, and refusing
unless it is empty just makes them delete the contents by hand first.
--]]
function Library.deleteTree(path)
    if lfs.attributes(path, "mode") ~= "directory" then return false end

    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            local child = path .. "/" .. entry
            if lfs.attributes(child, "mode") == "directory" then
                Library.deleteTree(child)
            else
                os.remove(child)
            end
        end
    end
    return lfs.rmdir(path) and true or false
end

--- Deletes a folder of the notebook tree, given its path relative to the root.
function Library.deleteFolder(rel)
    return Library.deleteTree(Library.abs(rel))
end

--[[--
Every folder in the notebook tree, depth first, as `{ rel, name, depth }`.

Used to say where something should be moved to. Kept here rather than walked by
the caller so that "what folders are there" has one answer, and so the recursion
cannot wander outside the notebook root.
--]]
function Library.allFolders(rel, depth, into)
    into = into or {}
    depth = depth or 0
    rel = rel or ""

    local dir = Library.abs(rel)
    if lfs.attributes(dir, "mode") ~= "directory" then return into end

    local names = {}
    for entry in lfs.dir(dir) do
        -- Sidecars are not places to put things; see the note in Library.list.
        if entry:sub(1, 1) ~= "." and not entry:match("%.sdr$") then
            if lfs.attributes(dir .. "/" .. entry, "mode") == "directory" then
                table.insert(names, entry)
            end
        end
    end
    table.sort(names)

    for _, name in ipairs(names) do
        local child = rel ~= "" and (rel .. "/" .. name) or name
        table.insert(into, { rel = child, name = name, depth = depth })
        Library.allFolders(child, depth + 1, into)
    end
    return into
end

--- True if `rel` is `ancestor` or lies inside it.
function Library.isWithin(rel, ancestor)
    if ancestor == "" then return true end
    if rel == ancestor then return true end
    return rel:sub(1, #ancestor + 1) == ancestor .. "/"
end

--[[--
Moves a notebook, an export or a folder into another folder.

The name is kept when it can be and made unique when it cannot, because a move
that stops halfway to ask about one name out of twenty is worse than a move that
lands a "(2)" beside something. Returns the new relative path, or nil and a
reason.
--]]
function Library.moveTo(item_rel, target_rel)
    local source = Library.abs(item_rel)
    local mode = lfs.attributes(source, "mode")
    if not mode then return nil, "missing" end

    local name = item_rel:match("[^/]+$")
    if mode == "directory" and Library.isWithin(target_rel, item_rel) then
        -- A folder cannot be put inside itself; the tree would be unreachable.
        return nil, "into_itself"
    end
    if (Library.parentOf(item_rel) or "") == target_rel then
        return item_rel
    end

    if not Library.ensureDir(target_rel) then return nil, "failed" end

    local base, ext = name:match("^(.*)(%.[^.]+)$")
    if mode == "directory" then base, ext = name, "" end
    base, ext = base or name, ext or ""

    local candidate = name
    local dest_rel = target_rel ~= "" and (target_rel .. "/" .. candidate) or candidate
    local n = 2
    while lfs.attributes(Library.abs(dest_rel), "mode") do
        candidate = string.format("%s (%d)%s", base, n, ext)
        dest_rel = target_rel ~= "" and (target_rel .. "/" .. candidate) or candidate
        n = n + 1
        if n > 999 then return nil, "exists" end
    end

    if not os.rename(source, Library.abs(dest_rel)) then
        return nil, "failed"
    end
    return dest_rel
end

--- The path of an item relative to the notebook root.
function Library.relOf(path)
    local root = Library.root()
    if path:sub(1, #root + 1) == root .. "/" then
        return path:sub(#root + 2)
    end
    return nil
end

--- A default name for a new notebook, based on today's date.
function Library.suggestName(folder)
    return Library.uniqueName(os.date("%Y-%m-%d"), folder)
end

return Library
