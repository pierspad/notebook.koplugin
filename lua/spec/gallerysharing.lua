-- Drive the production sharing controller one scheduled unit at a time.
package.path='./?.lua;./spec/?.lua;'..package.path
local support=require('support');support.installStubs()
require('uistubs').install({})
local Safe,Share,Export=require('safe'),require('share'),require('export')
local Library,Document=require('library'),require('document')
local queue,steps,sent,failed,copy_failure,cache,job_failure,begin_failure
local copies={}
Safe.later=function(_,fn) queue[#queue+1]=fn end
Share.stagingDir=function() return '/staged' end
Share.cachedExport=function() return cache end
Document.load=function() return true end
Library.copyFile=function(source,target)
 copies[#copies+1]={source,target};return not copy_failure
end
Library.deleteTree=function() end
Export.toPDF=function() error('sharing still runs a complete synchronous PDF export') end
Export.beginPDF=function(_,out)
 if begin_failure then return nil,'cannot create output' end
 local remaining=3
 return {step=function()
  steps=steps+1;remaining=remaining-1
  if job_failure then return 'error','disk full' end
  if remaining==0 then return 'done' end
  return 'working'
 end,out_path=out}
end
local Gallery={}
require('galleryexport')(Gallery,function(item) return item.is_pdf end,function(items) return items end)
local function run(options)
 queue={};steps=0;sent=nil;failed=nil;copies={}
 cache=options.cache;copy_failure=options.copy_failure
 job_failure=options.job_failure;begin_failure=options.begin_failure
 local g=setmetatable({_endSelection=function() end},{__index=Gallery})
 g:_shareMany({{path='/note.scribe',name='Note'}},'pdf',function(path,err) sent=path;failed=err end)
 assert(steps==0 and not sent,'share rendered before yielding to the UI')
 local ticks=0
 while #queue>0 do
  local previous=steps;ticks=ticks+1;assert(ticks<20,'sharing never completed')
  table.remove(queue,1)()
  assert(steps-previous<=1,'one UI callback rendered multiple export phases')
  if steps<3 and not job_failure and not begin_failure then assert(not sent,'shared a partial PDF') end
 end
 if job_failure or begin_failure or copy_failure then
  assert(not sent and failed,'failed PDF was offered for sharing')
 else
  assert(steps==3 and sent=='/staged/Note.pdf','completed PDF not offered exactly after export')
  if cache then assert(copies[1][1]==cache and copies[1][2]==sent,'cached export not staged') end
 end
end
run({});run({cache='/cache/note.pdf'})
run({job_failure=true});run({begin_failure=true});run({cache='/cache/note.pdf',copy_failure=true})
print('gallery sharing: phased PDF preparation, cache staging and failed-output handling passed')
