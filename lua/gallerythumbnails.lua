-- Deferred thumbnail work and cancellation belong to one gallery generation.
return function(Gallery)
local Thumbnail=require("thumbnail")
local Safe=require("safe")
local PAGE_W,PAGE_H=1860,2480
--[[--
Draws the pictures this screen is missing, one per tick.

Rendering a thumbnail means loading a whole notebook and rasterising a page of
it. Doing that while laying out meant the gallery could not appear until every
notebook on the screen had been read -- seconds of frozen panel on opening a
folder, with nothing to show that anything was happening. So the cards go up
immediately with a blank page on them and the pictures follow, one per tick, so
that taps and swipes are still answered while it happens.

The work is a queue on the gallery rather than a list captured by each run. It
used to be captured, with a token cancelling the run whenever a new layout
started -- and a layout starts for all sorts of reasons, including the one this
very code performs when it finishes. Whatever was left in a cancelled run was
dropped, which is why some cards kept their blank page while others filled in,
most visibly right after moving notebooks between folders.

Now a layout adds to the queue and the worker keeps going until it is empty.
Only leaving the folder, or the gallery, throws the work away -- and then it
ought to be thrown away.

Each picture is scheduled through `Safe.later`, never `UIManager:nextTick`, and
the difference is the difference between a slow screen and a dead device.
`handleInput` runs its tasks and repaints in a loop that only ends once nothing
more is due, and it reads input *after* that loop -- so a chain of tasks due
immediately means input is never read at all, for as long as the chain lasts.
With a folder of large notebooks on a device far slower than the one this was
written on, that is not a pause: it is a Kindle that has stopped answering, with
nothing to do but hold the power button. Scheduling a moment ahead instead lets
the loop settle between pictures, and a tap lands while they are still coming in.
--]]
function Gallery:_drawThumbnails(missing, w, h)
    for _, source in ipairs(missing) do
        if not self.thumb_queued[source] then
            self.thumb_queued[source] = true
            table.insert(self.thumb_queue, { source = source, w = w, h = h })
        end
    end

    if self.thumb_working or #self.thumb_queue == 0 then return end
    self.thumb_working = true

    local folder = self.folder
    local generation = self.thumb_generation
    local drew = false

    local function step()
        -- A cancelled worker must not clear the new folder's working flag.
        if self.thumb_generation~=generation then return end
        -- The folder changed, or the gallery is gone: these pictures belong to
        -- a screen nobody is looking at.
        if self.folder ~= folder or self.closed then
            self.thumb_working = false
            return
        end

        local job = table.remove(self.thumb_queue, 1)
        if not job then
            self.thumb_working = false
            if drew then
                self:_layout()
                self:_repaint()
            end
            return
        end

        -- Off the waiting list as it comes off the queue, not when it was put
        -- on: the flag is there to stop the same picture being queued twice
        -- while it waits, not to stop it ever being queued again. Left set, a
        -- notebook that failed once and was then written in never came back.
        self.thumb_queued[job.source] = nil
        self.thumb_tried[job.source] = Thumbnail.stamp(job.source) or true
        if Thumbnail.get(job.source, job.w, job.h, PAGE_W, PAGE_H) then
            drew = true
        end
        Safe.later("gallery:thumbnail", step)
    end

    Safe.later("gallery:thumbnail", step)
end

--- Forgets the pictures still waiting to be drawn.
function Gallery:_cancelThumbnails()
    self.thumb_generation=(self.thumb_generation or 0)+1
    self.thumb_working=false
    self.thumb_queue = {}
    self.thumb_queued = {}
end

end
