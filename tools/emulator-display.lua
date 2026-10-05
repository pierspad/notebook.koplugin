-- Desktop-only user patch: keep the Kindle framebuffer while scaling the window.
local ffi = require("ffi")
local SDL = require("ffi/SDL3")
local Framebuffer = require("ffi/framebuffer_SDL3")
local width = assert(tonumber(os.getenv("EMULATE_READER_W")))
local height = assert(tonumber(os.getenv("EMULATE_READER_H")))
local scale = tonumber(os.getenv("NOTEBOOK_EMULATOR_WINDOW_SCALE")) or 0.4
assert(scale > 0 and scale <= 1, "window scale must be between 0 and 1")
ffi.cdef[[bool SDL_SetWindowSize(SDL_Window *, int, int);]]
local window_w, window_h = math.floor(width * scale), math.floor(height * scale)
local open = SDL.open
SDL.open = function(...)
    open(...)
    SDL.w, SDL.h = width, height
    SDL.destroyTexture(SDL.texture)
    SDL.texture = SDL.createTexture(width, height)
    assert(SDL.SDL.SDL_SetWindowSize(SDL.screen, window_w, window_h))
    SDL.SDL.SDL_SyncWindow(SDL.screen)
    -- Framebuffer:init takes its initial geometry from these values.
    SDL.win_w, SDL.win_h = width, height
end
local init = Framebuffer.init
Framebuffer.init = function(self)
    init(self)
    -- Pointer coordinates use the physical window size, independently of BB.
    SDL.win_w, SDL.win_h = window_w, window_h
end
Framebuffer.resize = function(_, w, h)
    -- SDL scales the existing texture; retain the drawing coordinate system.
    SDL.win_w, SDL.win_h = w, h
end
