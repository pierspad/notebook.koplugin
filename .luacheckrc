-- Luacheck configuration for the Notebook KOReader plugin.

-- KOReader's own style runs long; wrapping to 80 would fight the codebase it
-- has to live in.
max_line_length = 150

-- Globals KOReader puts in place before a plugin loads.
globals = {
    "G_reader_settings",
}

-- `self` unused in a method is ordinary Lua OOP, not a mistake.
unused_args = false

-- Shadowing in nested closures is idiomatic here and reads fine.
redefined = false

-- The bench installs stubs into package.loaded and shares helpers between
-- suites; linting it as ordinary modules produces noise and no findings.
exclude_files = {
    "lua/spec/*",
}
