package.path='./?.lua;./spec/?.lua;'..package.path
require('support').installStubs()
local Document,Stroke=require('document'),require('stroke')
for _,batch in ipairs({false,true}) do
 local doc=Document:new('/tmp/bulkdelete.scribe')
 local all,chosen,remaining={},{},{}
 for i=1,1000 do
    local s=Stroke:new{tool='pen',width=2};s:addPoint(i,10,1)
    all[i]=s;doc:addStroke(s)
    if i%3~=0 then chosen[#chosen+1]=s else remaining[#remaining+1]=s end
 end
 -- Duplicate/stale selection members must not change ordering or erase more.
 chosen[#chosen+1]=chosen[1];chosen[#chosen+1]=Stroke:new{}
 local list=doc:getPage().strokes
 if batch then doc:beginBatch() end
 doc:removeStrokes(chosen)
 if batch then doc:commitBatch() end
 assert(doc:getPage().strokes==list,'deletion replaced the page list')
 local function check(expected)
    local got=doc:getPage().strokes;assert(#got==#expected,'incorrect count')
    for i,s in ipairs(expected) do assert(got[i]==s,'stacking order changed at '..i) end
 end
 check(remaining);doc:undo();check(all);doc:redo();check(remaining)
 local before=#doc.undo_stack
 doc:removeStrokes({chosen[#chosen]})
 assert(#doc.undo_stack==before,'missing member created history')
 doc:removeStrokes(doc:getPage().strokes);assert(#doc:getPage().strokes==0,'delete-all alias failed')
 doc:undo();check(remaining)
end
print('bulk deletion: stable order, duplicate/stale members, batching, undo/redo and delete-all')
