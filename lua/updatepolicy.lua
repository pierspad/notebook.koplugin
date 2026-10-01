-- Pure release/channel policy. No network, settings, filesystem or widgets.
local M = { API = "https://api.github.com/repos/pierspad/notebook.koplugin/releases/latest",
    WEEK = 7 * 24 * 3600, MAX_ZIP = 8 * 1024 * 1024 }
local ROOT = "https://github.com/pierspad/notebook.koplugin/releases/download/"
local function parts(version)
    if type(version) ~= "string" then return end
    local a,b,c,suffix = version:match("^v?(%d+)%.(%d+)%.(%d+)(.*)$")
    if not a or (suffix ~= "" and not suffix:match("^%-[%w.-]+$")) then return end
    return {tonumber(a),tonumber(b),tonumber(c)}, suffix
end
function M.newer(latest, current)
    local a,as = parts(latest)
    local b,bs = parts(current)
    if not a or not b or as ~= "" then return false end
    for i=1,3 do if a[i]~=b[i] then return a[i]>b[i] end end
    return bs ~= "" -- stable supersedes a prerelease of the same version.
end
function M.release(data)
    if type(data) ~= "table" or data.draft ~= false or data.prerelease ~= false then
        return nil, "Not a published stable release"
    end
    local p,s = parts(data.tag_name)
    if not p or s ~= "" then return nil, "Not a stable version tag" end
    local name = "notebook.koplugin-" .. data.tag_name .. ".zip"
    for _,asset in ipairs(type(data.assets)=="table" and data.assets or {}) do
        if type(asset)=="table" and asset.name==name and asset.state=="uploaded"
            and asset.browser_download_url==ROOT..data.tag_name.."/"..name
            and type(asset.size)=="number" and asset.size>0 and asset.size<=M.MAX_ZIP
            and asset.size%1==0 and type(asset.digest)=="string"
            and asset.digest:match("^sha256:%x+$") and #asset.digest==71 then
            return {tag=data.tag_name, url=asset.browser_download_url, size=asset.size,
                digest=asset.digest:sub(8):lower(), notes=type(data.body)=="string" and data.body or ""}
        end
    end
    return nil, "Stable release has no verified installable ZIP"
end
function M.due(now,last)
    return type(last)~="number" or last~=last or last>now or now-last>=M.WEEK
end
-- Archive paths are deliberately narrower than filesystem paths.
function M.entry(path, mode)
    if type(path)~="string" or (mode~="file" and mode~="directory")
        or path:find("[%c\\]") or path:sub(1,1)=="/" then return nil end
    path=path:gsub("/$", "")
    if path=="notebook.koplugin" and mode=="directory" then return "" end
    local rel=path:match("^notebook%.koplugin/(.+)$")
    if not rel or rel:find("//",1,true) then return nil end
    for segment in rel:gmatch("[^/]+") do
        if segment=="." or segment==".." then return nil end
    end
    return rel
end
return M
