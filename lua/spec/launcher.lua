-- Run the production entry point with a window stack that retains covered screens.
package.path='./?.lua;./spec/?.lua;'..package.path
require('support').installStubs()
require('uistubs').install({})
local UI=require('ui/uimanager')
local stack={};local created=0
UI.isWidgetShown=function(_,w) for _,v in ipairs(stack) do if v==w then return true end end return false end
UI.getTopmostVisibleWidget=function() return stack[#stack] end
UI.show=function(_,w) stack[#stack+1]=w end
UI.close=function(_,w)
    w.closed=true
    for i=#stack,1,-1 do if stack[i]==w then table.remove(stack,i) end end
end
local overrides={
    dispatcher={},document={},notebook={},
    gallery={new=function(_,o) created=created+1;o.folder=o.folder or '';return o end},
    library={ensureDir=function() return true end},
    launcherbar={register=function() end},
    share={available=function() return false end},
    updater={},
}
local chunk=assert(loadfile('./main.lua'))
local env=setmetatable({loadfile=function(path)
    if path:match('/loader.lua$') then
        return function() return function() return function(name)
            return overrides[name] or require(name)
        end end end
    end
    return loadfile(path)
end},{__index=_G})
setfenv(chunk,env)
local Plugin=chunk();local plugin=Plugin:extend{ui={}}
plugin:openNotebook()
local gallery=stack[#stack];gallery.folder='notes'
plugin:openNotebook()
assert(created==1 and #stack==1,'repeat launch duplicated gallery')
stack[#stack+1]={name='home',covers_fullscreen=true}
plugin:openNotebook()
assert(stack[#stack].on_open,'covered gallery launch remained on Home')
assert(#stack==2,'covered gallery launch duplicated window stack')
assert(stack[#stack].folder=='notes','reopening lost current folder')
print('launcher: repeated launch and covered gallery reopening passed')
-- Every entry point keeps a single live notebook and validates replacements.
local remember={}
overrides.recents={remember=function(path) remember[#remember+1]=path end}
overrides.library.pathFor=function(name,folder) return '/data/notebook/'..(folder~='' and folder..'/' or '')..name..'.scribe' end
overrides.document.new=function(_,path)
    return {path=path,setTemplate=function() end,load=function() return not path:find('broken') end,
        save=function() return not path:find('unsavable') end}
end
overrides.notebook.new=function(_,o)
    o._saveForSwitch=function(self) return self.document:save() end
    return o
end
local attr=require('libs/libkoreader-lfs').attributes
require('libs/libkoreader-lfs').attributes=function(path,what)
    if path:find('broken') then return what=='mode' and 'file' or {mode='file'} end
    return attr(path,what)
end
for i=1,30 do
    assert(plugin:_openByName('note'..i,'',nil,'blank'))
    assert(#stack==3 and stack[#stack].document.path:find('note'..i..'.scribe',1,true),
        'repeated opens stacked canvases')
end
local active=stack[#stack];local undo={};active.document.undo_stack=undo
local original=active.document
assert(plugin:_openByName('note30','',nil,nil,active))
assert(stack[#stack]==active and active.document==original and not active.closed,
    'opening the active notebook replaced its document/history')
assert(not plugin:_openByName('broken','',nil,nil,active))
assert(UI:isWidgetShown(active) and not active.closed and active.document.undo_stack==undo)
stack[#stack]=nil -- dismiss the load-error notification
assert(not plugin:_openByName('unsavable','',nil,'blank',active))
assert(UI:isWidgetShown(active) and not active.closed)
stack[#stack]=nil -- dismiss the new-notebook save error
active.document.save=function() return false,'disk full' end
assert(not plugin:_openByName('valid','',nil,'blank',active))
assert(stack[#stack]==active and not active.closed and #stack==3)
assert(#remember==30,'failed switch polluted recent notebooks')
print('launcher replacements: 30 single-canvas switches; failed load/new save/current save preserve active notebook')
