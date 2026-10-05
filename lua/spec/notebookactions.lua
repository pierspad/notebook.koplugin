package.path='./?.lua;./spec/?.lua;'..package.path
local support=require('support');support.installStubs()
local fs={['/data/notebook/a.scribe']={mode='file'},['/data/notebook/work/b.scribe']={mode='file'}}
local record=require('uistubs').install(fs)
local settings={}
G_reader_settings={readSetting=function(_,k) return settings[k] end,saveSetting=function(_,k,v) settings[k]=v end}
require('device').input.TOOL_TYPE_ERASER=2
require('device').input.TOOL_TYPE_HIGHLIGHTER=3
local Notebook,Document=require('notebook'),require('document')
local Screen=require('device').screen;Screen.bb=support.FakeBB.new(600,800)
Screen.refreshFast=function() end;Screen.refreshUI=function() end
local UI=require('ui/uimanager');local queue={}
UI.scheduleIn=function(_,_,fn) queue[fn]=true end
UI.unschedule=function(_,fn) queue[fn]=nil end
local nb=Notebook:new{document=Document:new('/data/notebook/a.scribe'),title='a'}
local order={};nb:_finishInteraction();nb.document.dirty=true
nb._finishInteraction=function() order[#order+1]='finish' end
nb.document.save=function() order[#order+1]='save';return false,'disk full' end
nb.on_request=function() order[#order+1]='switch' end
assert(not nb:_requestNotebook('new'))
assert(table.concat(order,',')=='finish,save' and not nb.closed,'failed save lost canvas')
order={};nb.document.save=function() order[#order+1]='save';return true end
assert(nb:_requestNotebook('pdf') and table.concat(order,',')=='finish,save,switch')
nb.document.dirty=false;order={}
assert(nb:_requestNotebook('new') and table.concat(order,',')=='finish,switch',
    'clean existing notebook was written again during switching')
nb.document.path='/data/notebook/unsaved.scribe';order={}
assert(nb:_saveForSwitch() and table.concat(order,',')=='finish,save','new blank notebook was not saved')
nb.document.path='/data/notebook/a.scribe'
nb._finishInteraction=function() order[#order+1]='finish';nb.document.dirty=true end
order={};assert(nb:_saveForSwitch() and table.concat(order,',')=='finish,save',
    'finishing an active stroke skipped its save')

-- File-action menus close before dispatch; tool-option menus remain selectable.
nb:_showNotebookMenu();local menu=record.shown[#record.shown]
assert(menu.close_on_select and #menu.actions==8)
assert(menu.actions[1].section and menu.actions[5].section and menu.actions[7].section)
assert(menu.actions[1].pair and menu.actions[3].pair and menu.actions[5].pair)
assert(nb.settings_button.selected and not nb.tool_buttons[1].selected,
    'settings did not replace the selected tool highlight')
assert(nb.canvas.tool=='pen', 'opening settings changed the drawing tool')
menu:onCloseWidget()
assert(not nb.settings_button.selected and nb.tool_buttons[1].selected,
    'closing settings did not restore the drawing tool highlight')
menu.action_rows[1].row:onTap()
assert(record.closed[#record.closed]==menu,'file menu retained modal ownership')
assert(not require('safe').failed)
-- MRU spans folders, bounds growth and refuses traversal/malformed entries.
local Recents=require('recents')
Recents.remember('/data/notebook/work/b.scribe');Recents.remember('/data/notebook/a.scribe')
assert(Recents.list()[1]=='a.scribe' and Recents.list()[2]=='work/b.scribe')
nb:_showRecentNotebooks();local recent_menu=record.shown[#record.shown]
assert(recent_menu.actions[1].preview_source=='/data/notebook/work/b.scribe',
    'recent notebooks have no preview source')
local Safe,Thumbnail=require('safe'),require('thumbnail')
local later,get=Safe.later,Thumbnail.get;local pending,reads={},0
Safe.later=function(_,fn) pending[#pending+1]=fn end
Thumbnail.get=function() reads=reads+1;return nil end
nb:_showRecentNotebooks();local closing=record.shown[#record.shown]
closing:onCloseWidget()
while #pending>0 do table.remove(pending,1)() end
assert(reads==0,'closed recent menu continued reading notebooks')
Safe.later,Thumbnail.get=later,get
settings.notebook_recent={'../a.scribe','/a.scribe','missing.scribe',false,'a.scribe','a.scribe','work/b.scribe'}
local list=Recents.list('a.scribe');assert(#list==1 and list[1]=='work/b.scribe')
for i=1,12 do fs['/data/notebook/'..i..'.scribe']={mode='file'};Recents.remember('/data/notebook/'..i..'.scribe') end
assert(#settings.notebook_recent==8 and settings.notebook_recent[1]=='12.scribe')
-- A stale oversized settings list cannot stat every historical entry after filling the menu.
local lfs=require('libs/libkoreader-lfs');local attributes=lfs.attributes;local stats=0
lfs.attributes=function(...) stats=stats+1;return attributes(...) end
for i=1,1000 do settings.notebook_recent[#settings.notebook_recent+1]='missing'..i..'.scribe' end
assert(#Recents.list()==8 and stats==8,'MRU scanned past its display limit')
lfs.attributes=attributes
-- Settings preserve the third barrel action across reopening.
nb:_setSetting('barrel_button_tool','lasso');nb.canvas.barrel_button_tool='eraser';nb:_loadSettings()
assert(nb.canvas.barrel_button_tool=='lasso')
nb.canvas.barrel_down=true
assert(nb.canvas:resolveTool(2)=='lasso');nb.canvas.barrel_down=false
nb.canvas.physical_pen_tool=2
assert(nb.canvas:resolveTool(2)=='eraser','physical eraser became lasso')
print('notebookactions: save failures, ordering, modal cleanup, MRU filtering/bounds and barrel persistence passed')
-- The barrel lasso also works in zoom, without saving its outline as ink.
local Canvas,Stroke=require('canvas'),require('stroke')
local doc=Document:new('/zoom-lasso');local stroke=Stroke:new{width=3}
stroke:addPoint(100,150);stroke:addPoint(130,170);doc:addStroke(stroke)
local c=Canvas:new{document=doc,content={x=0,y=50,w=600,h=750}}
c.zoom=2;c.zoom_x=0;c.zoom_y=50
local picked;c._showLassoMenu=function(_,selected) picked=selected end
for _,p in ipairs({{160,220},{300,220},{300,280},{160,280},{160,220}}) do
    c:_zoomStylus({id=1,x=p[1],y=p[2]},'lasso')
end
c:_zoomStylus({id=-1},'lasso')
assert(picked and picked[1]==stroke and #doc:getPage().strokes==1,'zoom lasso failed or became ink')
assert(not c.pen_down and not c.zoom_stroke)
print('barrel lasso: zoom selection preserves zoom, ink and release state')
