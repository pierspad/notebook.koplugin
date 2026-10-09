-- Pure release/channel policy. No network, settings, filesystem or widgets.
local M = { API = "https://api.github.com/repos/pierspad/notebook.koplugin/releases/latest",
    API_ALL = "https://api.github.com/repos/pierspad/notebook.koplugin/releases?per_page=100",
    WEEK = 7 * 24 * 3600, MAX_ZIP = 8 * 1024 * 1024 }
local ROOT = "https://github.com/pierspad/notebook.koplugin/releases/download/"
local function parts(version)
    if type(version) ~= "string" then return end
    local a,b,c,suffix = version:match("^v?(%d+)%.(%d+)%.(%d+)(.*)$")
    if not a or (suffix ~= "" and not suffix:match("^%-[%w.-]+$")) then return end
    if suffix ~= "" then
        local identifiers = suffix:sub(2)
        if identifiers:sub(1,1)=="." or identifiers:sub(-1)=="."
            or identifiers:find("..",1,true) then return end
        for id in identifiers:gmatch("[^.]+") do
            if id:match("^%d+$") and #id>1 and id:sub(1,1)=="0" then return end
        end
    end
    return {tonumber(a),tonumber(b),tonumber(c)}, suffix
end
function M.newer(latest, current, include_prereleases)
    local a,as = parts(latest)
    local b,bs = parts(current)
    if not a or not b or (as ~= "" and include_prereleases ~= true) then return false end
    for i=1,3 do if a[i]~=b[i] then return a[i]>b[i] end end
    if as == bs then return false end
    if as == "" then return true end -- stable supersedes its prereleases.
    if bs == "" then return false end
    local ai,bi={},{}
    for id in as:sub(2):gmatch("[^.]+") do ai[#ai+1]=id end
    for id in bs:sub(2):gmatch("[^.]+") do bi[#bi+1]=id end
    for i=1,math.max(#ai,#bi) do
        local x,y=ai[i],bi[i]
        if not x then return false end
        if not y then return true end
        if x~=y then
            local xn,yn=x:match("^%d+$"),y:match("^%d+$")
            if xn and yn then
                if #x~=#y then return #x>#y end
                return x>y
            end
            if xn then return false end
            if yn then return true end
            return x>y
        end
    end
    return false
end
function M.release(data, include_prereleases)
    if type(data) ~= "table" or data.draft ~= false
        or (data.prerelease ~= false and not (include_prereleases == true and data.prerelease == true)) then
        return nil, "Not a published release in the selected channel"
    end
    local p,s = parts(data.tag_name)
    if not p or (s ~= "") ~= data.prerelease then return nil, "Invalid release version tag" end
    local name = "notebook.koplugin-" .. data.tag_name .. ".zip"
    for _,asset in ipairs(type(data.assets)=="table" and data.assets or {}) do
        if type(asset)=="table" and asset.name==name and asset.state=="uploaded"
            and asset.browser_download_url==ROOT..data.tag_name.."/"..name
            and type(asset.size)=="number" and asset.size>0 and asset.size<=M.MAX_ZIP
            and asset.size%1==0 and type(asset.digest)=="string"
            and asset.digest:match("^sha256:%x+$") and #asset.digest==71 then
            return {tag=data.tag_name, prerelease=data.prerelease, url=asset.browser_download_url, size=asset.size,
                digest=asset.digest:sub(8):lower(), notes=type(data.body)=="string" and data.body or ""}
        end
    end
    return nil, "Release has no verified installable ZIP"
end
-- GitHub release order is not version order; skip drafts and incomplete ZIPs.
function M.select(data, include_prereleases)
    if type(data) ~= "table" then return nil, "Invalid release list" end
    local best
    for _,candidate in ipairs(data) do
        local release = M.release(candidate, include_prereleases)
        if release and (not best or M.newer(release.tag,best.tag,include_prereleases)) then
            best = release
        end
    end
    if best then return best end
    return nil, "No verified release in the selected channel"
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
