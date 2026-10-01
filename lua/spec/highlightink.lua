package.path='./?.lua;./spec/?.lua;'..package.path
local support=require('support');support.installStubs()
local Ink=require('highlightink')
local FakeBB=support.FakeBB
-- Independent membership oracle: the four square-side inequalities constrain
-- an interval of t. No polygon construction, rasterizer or stamp sampling.
local function inside(x,y,x0,y0,r0,x1,y1,r1,first,last,steps)
    local low,high=first/steps,last/steps
    local dx,dy,dr=x1-x0,y1-y0,r1-r0
    for _,q in ipairs({{x-x0-r0,-dx-dr},{x0-x-r0,dx-dr},
        {y-y0-r0,-dy-dr},{y0-y-r0,dy-dr}}) do
        if q[2]==0 then if q[1]>1e-8 then return false end
        elseif q[2]>0 then high=math.min(high,-q[1]/q[2])
        else low=math.max(low,-q[1]/q[2]) end
    end
    return low<=high+1e-8
end
math.randomseed(1741)
for i=1,400 do
    local x0,y0=math.random(-400,1000)/10,math.random(-400,1000)/10
    local x1,y1=math.random(-400,1000)/10,math.random(-400,1000)/10
    if i%10==0 then x1,y1=x0,y0 end
    local r0,r1=math.random(5,350)/10,math.random(5,350)/10
    if i%2==0 then r1=r0 end
    local first,last,steps=math.random(0,4),math.random(6,10),10
    for _,preview in ipairs({false,true}) do
        local bb=FakeBB.new(96,88)
        for x=0,95 do bb:set(x,32,100) end
        Ink.drawSegment(bb,x0,y0,r0,x1,y1,r1,160,first,last,steps,preview)
        for y=0,87 do for x=0,95 do
            local expected=y==32 and 100 or 255
            if inside(x,y,x0,y0,r0,x1,y1,r1,first,last,steps) then
                if preview then if (x+y)%4==0 then expected=0 end
                else expected=math.min(expected,160) end
            end
            assert(bb:get(x,y)==expected,string.format('continuous marker case %d pixel %d,%d',i,x,y))
        end end
    end
end
for _,preview in ipairs({false,true}) do
    local actual,expected=FakeBB.new(96,88),FakeBB.new(96,88)
    local points={{30.2,30.5,18},{32.7,31.1,18},{33.1,33.8,20},{31.4,35.2,15},{30.2,30.5,18}}
    for i=1,#points do
        local a,b=points[math.max(1,i-1)],points[i]
        Ink.drawSegment(actual,a[1],a[2],a[3],b[1],b[2],b[3],160,0,1,1,preview,i>1)
        Ink.drawSegment(expected,a[1],a[2],a[3],b[1],b[2],b[3],160,0,1,1,preview)
    end
    for y=0,87 do for x=0,95 do
        assert(actual:get(x,y)==expected:get(x,y),'incremental marker lost shared coverage')
    end end
end
print('marker: 800 continuous sweeps match independent inequalities; pressure, clipping, preview and incremental reversals passed')
