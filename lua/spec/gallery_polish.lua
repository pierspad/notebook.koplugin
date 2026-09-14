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
