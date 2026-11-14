#!/usr/bin/env luajit
-- Scans performance-critical LuaJIT modules for inner closures (FNEW) and
-- open-upvalue cleanup bytecodes (UCLO). In ARMv7 LuaJIT, a local helper
-- closure inside a hot function forces UCLO across returns and kicks the
-- entire caller back into the interpreter.

local bc = require("jit.bc")
local util = require("jit.util")

local root = (arg and arg[1]) or "lua"

-- Each entry lists a module relative to `lua/` and optional exempt outer
-- wrappers (line-start functions that intentionally wrap non-hot generators,
-- error boundaries, or job state machines). Functions outside any exempt list
-- must have zero UCLO and zero inner FNEW bytecodes.
local WATCHED = {
    ["penink.lua"] = {},
    ["highlightink.lua"] = {},
    ["geometryink.lua"] = {},
    ["polygonink.lua"] = {},
    ["template.lua"] = {},
    ["lasso.lua"] = {},
    ["markerclip.lua"] = {},
    ["canvasrender.lua"] = {},
    ["svg.lua"] = {
        -- Error boundary pcall wrapper & callback adapter once per SVG file.
        max_fn_line_exempt = { toSVG = true, writeDocumentSVG = true },
    },
    ["xopp.lua"] = {
        -- pageLayout pcall + top-level toXOPP streaming setup once per export.
        exempt_named = { pageLayout = true, toXOPP = true },
    },
    ["markerarea.lua"] = {
        -- Area.parts returns an iterator closure intentionally (1 call/stroke).
        exempt_named = { parts = true },
    },
    ["renderer.lua"] = {
        -- drawDashedRect runs once per lasso frame and uses span/hline/vline helpers.
        exempt_named = { drawDashedRect = true },
    },
    ["export.lua"] = {
        -- beginPDF allocates per-job closures once per PDF document.
        exempt_named = { beginPDF = true },
    },
}

local function findFuncRanges(source)
    local by_start = {}
    local line_no = 0
    for line in source:gmatch("([^\n]*)\n?") do
        line_no = line_no + 1
        local name = line:match("^%s*local%s+function%s+([%w_]+)")
            or line:match("^%s*function%s+[%w_]+[.:]([%w_]+)")
        if name then
            by_start[line_no] = name
        end
    end
    return by_start
end

local function scanFile(rel, policy)
    local path = root .. "/" .. rel
    local fh = assert(io.open(path, "rb"))
    local src = fh:read("*a")
    fh:close()
    local line_names = findFuncRanges(src)
    local chunk = assert(loadfile(path))

    local violations = {}
    local function visit(proto, inherited_exempt)
        local fi = util.funcinfo(proto)
        local start_line = fi.linedefined or 0
        local fn_name = line_names[start_line]
        local exempt = inherited_exempt
        if fn_name then
            if policy.exempt_named and policy.exempt_named[fn_name] then
                exempt = true
            elseif policy.max_fn_line_exempt and policy.max_fn_line_exempt[fn_name] then
                exempt = true
            end
        end

        if start_line > 0 and not exempt then
            local chunks = {}
            local writer = {
                write = function(_, ...)
                    for i = 1, select("#", ...) do
                        chunks[#chunks + 1] = select(i, ...)
                    end
                end,
                flush = function() end,
            }
            bc.dump(proto, writer, false)
            local dump = table.concat(chunks)
            for bcline in dump:gmatch("[^\n]+") do
                if bcline:find("%sUCLO%s") or bcline:find("%sFNEW%s") then
                    violations[#violations + 1] = string.format("%s:%d (%s): %s",
                        rel, start_line, fn_name or "anon", bcline:match("^%s*(.-)%s*$"))
                end
            end
        end

        for i = -1, -512, -1 do
            local k = util.funck(proto, i)
            if k == nil then break end
            if type(k) == "proto" then
                visit(k, exempt)
            end
        end
    end

    visit(chunk, false)
    return violations
end

local all_violations = {}
local checked = 0
local names = {}
for name in pairs(WATCHED) do names[#names + 1] = name end
table.sort(names)

for _, rel in ipairs(names) do
    checked = checked + 1
    local v = scanFile(rel, WATCHED[rel])
    for i = 1, #v do
        all_violations[#all_violations + 1] = v[i]
    end
end

if #all_violations > 0 then
    io.stderr:write("JIT hygiene check FAILED (inner UCLO/FNEW in hot path):\n")
    for i = 1, #all_violations do
        io.stderr:write("  " .. all_violations[i] .. "\n")
    end
    os.exit(1)
end

print(string.format("jit-hygiene: %d hot modules passed (0 UCLO/inner-FNEW regressions)", checked))
