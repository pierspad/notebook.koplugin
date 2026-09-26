-- Shared pressure response in page coordinates, for stylus, finger and zoom.
local Pressure = {}

function Pressure.sample(style, stroke, x, y, raw, elapsed_ms)
    if not style or style == "fineliner" then return 1 end
    local p = raw and math.max(0,math.min(1,raw/4095)) or 1
    if stroke and stroke.tool == "pen" and stroke:count() > 0 then
        local lx,ly,lp=stroke:getPoint(stroke:count())
        local distance=math.sqrt((x-lx)^2+(y-ly)^2)
        if raw == nil then
            p=math.max(0.35,1-distance/math.max(1,elapsed_ms or 20)*0.12)
        end
        p=lp+(p-lp)*(1-math.exp(-distance/12))
    end
    return p
end

return Pressure
