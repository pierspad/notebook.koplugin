-- Readable plain text for GitHub release notes in KOReader's TextViewer.
local M={}
function M.plain(text)
    text=(text or ""):gsub("\r\n","\n")
    text=text:gsub("!?%[([^%]]+)%]%(([^%)]+)%)",function(label,url)
        if label==url then return url end
        return label.." ("..url..")"
    end)
    local lines={}
    for line in (text.."\n"):gmatch("(.-)\n") do
        line=line:gsub("^%s*#+%s+", ""):gsub("%s+#+%s*$", "")
        line=line:gsub("^%s*[%*%-]%s+", "• "):gsub("^%s*>%s?", "")
        if not line:match("^%s*```") then
            line=line:gsub("%*%*([^*]+)%*%*", "%1"):gsub("__([^_]+)__", "%1")
                :gsub("`([^`]+)`", "%1")
            lines[#lines+1]=line
        end
    end
    return table.concat(lines,"\n")
end
return M
