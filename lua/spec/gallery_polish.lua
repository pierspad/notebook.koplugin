package.path = './?.lua;./spec/?.lua;' .. package.path
local support = require('support')
local ui = require('uistubs')
support.installStubs()
local rec = ui.install({ ['/data']={mode='directory'}, ['/data/notebook']={mode='directory'} })
local Gallery = require('gallery')
local g = Gallery:new{}
local a, b = {path='a'}, {path='b'}
g.selection = {}
g.cards = {{item=a,dimen={x=10,y=10,w=20,h=20}}, {item=b,dimen={x=60,y=10,w=20,h=20}}}
local layouts = 0
g._layout = function() layouts = layouts + 1 end
g:onGalleryPan(nil, {start_pos={x=15,y=15},pos={x=75,y=15}})
assert(g.selection.a and g.selection.b, 'drag selects crossed cards')
g:onGalleryPan(nil, {pos={x=15,y=15}})
assert(g.selection.a and g.selection.b, 'retrace does not toggle')
assert(layouts == 0, 'drag must not reload thumbnails')
local page = g.page
g:onGallerySwipe(nil, {direction='west'})
assert(g.page == page, 'selection drag cannot page')
g:onGalleryPanRelease(nil, {pos={x=15,y=15}})
assert(not g.selection_drag, 'release clears drag')
assert(layouts == 1, 'header updates once on release')
g.selection = nil
assert(not g:onGalleryPan(nil,{pos={x=15,y=15}}), 'ordinary browsing ignores pan')
local rebuilt = 0
g._rebuild = function() rebuilt = rebuilt + 1 end
local Library = require('library')
Library.deletePath = function() return true end
g:_deleteMany({a,b})
assert(layouts == 1 and rebuilt == 1, 'delete rebuilds only once')
package.loaded['ui/widget/inputdialog'].onShowKeyboard = function() end
g:_askName('New folder', '', function() end, {'Work','Personal'})
local dialog = rec.shown[#rec.shown]
assert(#dialog.buttons == 2, 'presets share the custom name dialog')
print('gallery polish passed')
-- Navigate before the old thumbnail tick fires: the new folder must get a worker.
local Safe,Thumbnail=require('safe'),require('thumbnail')
local old_later,old_get=Safe.later,Thumbnail.get
local callbacks,rendered={},{}
Safe.later=function(_,fn) callbacks[#callbacks+1]=fn end
Thumbnail.get=function(source) rendered[#rendered+1]=source;return true end
g.folder='old';g.thumb_working=false;g.thumb_queue={};g.thumb_queued={}
g:_drawThumbnails({'old.scribe'},100,120)
g._rebuild=function(self) self:_drawThumbnails({self.folder..'.scribe'},100,120) end
g:_goTo('new')
local limit=0
while #callbacks>0 do
    limit=limit+1;assert(limit<20,'thumbnail worker did not settle')
    table.remove(callbacks,1)()
end
assert(#rendered==1 and rendered[1]=='new.scribe','folder switch stranded new thumbnails or rendered stale work')
assert(not g.thumb_working and #g.thumb_queue==0,'thumbnail worker retained pending state')
rendered={}
g:_goTo('one');g:_goTo('two');g:_goTo('one')
while #callbacks>0 do table.remove(callbacks,1)() end
assert(#rendered==1 and rendered[1]=='one.scribe','returning to the original folder revived stale workers')
g:_goTo('closed');g:onCloseWidget()
while #callbacks>0 do table.remove(callbacks,1)() end
assert(#rendered==1 and not g.thumb_working,'closing the gallery rendered pending thumbnails')

-- Repaint thumbnails in visible batches without restarting the queue.
callbacks,rendered={},{}
local rendered_set,layouts,repaints={},0,0
local sources={}
for i=1,7 do sources[i]='progress'..i..'.scribe' end
g.folder='progress';g.closed=false;g.thumb_working=false;g.thumb_queue={};g.thumb_queued={}
g._layout=function(self)
    layouts=layouts+1
    local missing={}
    for _,source in ipairs(sources) do
        if not rendered_set[source] then missing[#missing+1]=source end
    end
    self:_drawThumbnails(missing,100,120)
end
g._repaint=function() repaints=repaints+1 end
Thumbnail.get=function(source)
    rendered[#rendered+1]=source
    rendered_set[source]=true
    return true
end
g:_drawThumbnails(sources,100,120)
local function runThumbnailTick()
    local callback=table.remove(callbacks,1)
    assert(callback,'thumbnail worker stopped before the queue emptied')
    callback()
end
for _=1,2 do runThumbnailTick() end
assert(layouts==0 and repaints==0,'gallery repainted before three completed thumbnails')
runThumbnailTick()
assert(layouts==1 and repaints==1,'gallery did not repaint after three completed thumbnails')
for _=1,3 do runThumbnailTick() end
assert(layouts==2 and repaints==2,'gallery did not repaint after six completed thumbnails')
runThumbnailTick()
assert(#rendered==7,'progressive relayout duplicated or lost thumbnail work')
assert(layouts==2 and repaints==2,'gallery repainted before the worker drained its queue')
runThumbnailTick()
assert(layouts==3 and repaints==3,'gallery did not paint the final partial batch')
assert(#callbacks==0 and not g.thumb_working and #g.thumb_queue==0,
    'progressive repaint created a thumbnail worker cycle')
Safe.later,Thumbnail.get=old_later,old_get
print('gallery thumbnails: rapid folder switches, return navigation and close cancel stale work')

-- Grid density toggle: 3x2 <-> 4x3 and vertical centering
local saved_settings = {}
G_reader_settings = {
    readSetting = function(self, k) return saved_settings[k] end,
    saveSetting = function(self, k, v) saved_settings[k] = v end,
    flush = function() end,
}
local items = {}
for i = 1, 12 do items[#items + 1] = { name = 'nb' .. i, path = '/data/notebook/nb' .. i .. '.scribe' } end
local g2 = Gallery:new{ items = items }
g2.dimen = { x = 0, y = 0, w = 1000, h = 1400 }
g2:_layout()

local function hasIcon(widget, name, seen)
    if type(widget) ~= 'table' then return false end
    seen = seen or {}
    if seen[widget] then return false end
    seen[widget] = true
    if widget.icon == name then return true end
    for _, child in pairs(widget) do
        if hasIcon(child, name, seen) then return true end
    end
    return false
end

local density_header = g2:_buildHeader()
assert(hasIcon(density_header, 'notebook.grid-4x3'),
    '3x2 density should show the 4x3 grid disposition as its next action')
assert(g2.columns == 3, 'initial density is 3 columns')
local per_page_3 = g2.per_page
assert(per_page_3 == 6, '3 columns fits 6 per page (3x2), got ' .. tostring(per_page_3))

g2:_toggleDensity()
assert(g2.columns == 4, 'toggled density to 4 columns')
assert(saved_settings['notebook_gallery_columns'] == 4, 'columns setting persisted')
local density_header_4 = g2:_buildHeader()
assert(hasIcon(density_header_4, 'notebook.grid-3x2'),
    '4x3 density should show the 3x2 grid disposition as its next action')
local per_page_4 = g2.per_page
assert(per_page_4 == 12, '4 columns fits 12 per page (4x3), got ' .. tostring(per_page_4))

g2:_toggleDensity()
assert(g2.columns == 3 and saved_settings['notebook_gallery_columns'] == 3, 'toggled back to 3 columns')
assert(g2.per_page == 6, 'back to 6 per page')
print('gallery density: toggle between 3x2 and 4x3 preserves settings and updates per_page')
