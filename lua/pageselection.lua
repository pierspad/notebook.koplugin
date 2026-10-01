-- Export views share immutable pages; editing/history remain on the original document.
local M={}
function M.parse(text,count)
    if type(text)~="string" or type(count)~="number" or count<1 or count%1~=0 or count==math.huge then return nil,"Invalid page range" end
    text=text:match("^%s*(.-)%s*$"):gsub(";",",")
    if text=="all" then local all={};for i=1,count do all[i]=i end;return all end
    if text=="" or text:sub(-1)=="," then return nil,"Invalid page range" end
    local selected={}
    for token in (text..","):gmatch("(.-),") do
        token=token:match("^%s*(.-)%s*$")
        local first,last=token:match("^(%d*)%s*%-%s*(%d*)$")
        if first and (first~="" or last~="") then
            first=first~="" and first or "1"
            last=last~="" and last or tostring(count)
        elseif first then return nil,"Invalid page range" end
        if not first and token:match("^%d+$") then first,last=token,token end
        first,last=tonumber(first),tonumber(last)
        if not first or first<1 or last<first or last>count then return nil,"Invalid page range" end
        for i=first,last do selected[i]=true end
    end
    local out={};for i=1,count do if selected[i] then out[#out+1]=i end end
    if #out==0 then return nil,"Invalid page range" end
    return out
end
-- Canonical compact ranges keep the editable bar in sync with checkboxes.
function M.format(indices)
    local ranges={}
    local i=1
    while i<=#indices do
        local first,last=indices[i],indices[i]
        while indices[i+1]==last+1 do i=i+1;last=indices[i] end
        ranges[#ranges+1]=first==last and tostring(first) or first.."-"..last
        i=i+1
    end
    return table.concat(ranges,",")
end
function M.view(doc,indices)
    if type(indices)~="table" or #indices==0 then return nil,"No selected pages" end
    local pages,mapping,seen={},{},{}
    for i,index in ipairs(indices) do
        if type(index)~="number" or index%1~=0 or not doc.pages[index] or seen[index] then
            return nil,"Invalid selected page"
        end
        seen[index]=true
        local page=doc.pages[index]
        if page.background and not page.background.page then
            local background={};for k,v in pairs(page.background) do background[k]=v end
            background.page=index
            page={strokes=page.strokes,template=page.template,background=background}
        end
        pages[i],mapping[i]=page,index
    end
    return setmetatable({pages=pages,current_page=1,
        pageCount=function() return #pages end,
        templateFor=function(_,index) return doc:templateFor(mapping[index or 1]) end,
        hasPDFBackgrounds=function()
            for _,page in ipairs(pages) do if page.background then return true end end
            return false
        end,
    },{__index=doc})
end
return M
