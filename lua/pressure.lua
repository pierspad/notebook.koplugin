-- Some Scribe virtual stylus bridges omit ABS_PRESSURE. Query the physical
-- digitizer's current pressure without consuming, grabbing or injecting input.
local Pressure = {}
local declared = false

function Pressure.open()
    local ok, ffi = pcall(require, "ffi")
    if not ok then return nil end
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes("/sys/class/input", "mode") ~= "directory" then return nil end
    if not declared then ffi.cdef[[
        typedef struct { int value, minimum, maximum, fuzz, flat, resolution; } notebook_absinfo;
        int open(const char *pathname, int flags, ...);
        int close(int fd);
        int ioctl(int fd, unsigned long request, ...);
    ]]; declared = true end
    for name in lfs.dir("/sys/class/input") do
        if name:match("^event%d+$") then
            local file = io.open("/sys/class/input/"..name.."/device/name", "r")
            local label = file and file:read("*l")
            if file then file:close() end
            if label == "WacomDigitizer" then
                local fd = ffi.C.open("/dev/input/"..name, 0)
                if fd >= 0 then
                    local info = ffi.new("notebook_absinfo[1]")
                    local sensor = {}
                    function sensor:read()
                        if fd < 0 or ffi.C.ioctl(fd, 0x80184558, info) ~= 0 then return nil end
                        local span = info[0].maximum - info[0].minimum
                        if span <= 0 then return nil end
                        return math.max(0, math.min(4095,
                            (info[0].value-info[0].minimum) * 4095 / span))
                    end
                    function sensor:close()
                        if fd >= 0 then ffi.C.close(fd); fd = -1 end
                    end
                    if sensor:read() then return sensor end
                    sensor:close()
                end
            end
        end
    end
end

return Pressure
