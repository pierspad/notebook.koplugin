-- File actions keep the current canvas alive until a replacement is ready.
local ActionMenu=require("actionmenu")
local Diagnostics=require("diagnostics")
local InfoMessage=require("ui/widget/infomessage")
local Library=require("library")
local Recents=require("recents")
local UIManager=require("ui/uimanager")
local _=require("i18n")
local Actions={}
local function showActions(title, actions, on_dismiss, preferred_row_height)
    local menu
    local screen=require("device").screen
    local row_height=preferred_row_height or math.min(screen:scaleBySize(52),math.floor(screen:getHeight()/(#actions+4)))
    menu=ActionMenu:new{title=title,actions=actions,row_height=row_height,close_on_select=true,
        width=math.floor(screen:getWidth()*0.86),on_dismiss=on_dismiss}
    UIManager:show(menu)
    return menu
end
function Actions:_saveForSwitch()
    self:_finishInteraction()
    -- Actions and the launcher both finalize switching. Once the first save
    -- succeeds, avoid writing the same complete file again in the second step.
    if self.document.dirty==false and self.document.path
        and require("libs/libkoreader-lfs").attributes(self.document.path,"mode")=="file" then return true end
    local ok,err=self.document:save()
    if not ok then
        UIManager:show(InfoMessage:new{text=_("Could not save the notebook. It has been left open.").."\n\n"..tostring(err or "")})
        return false
    end
    return true
end
function Actions:_requestNotebook(kind, value)
    if self.closed or not self.on_request or not self:_saveForSwitch() then return false end
    self:on_request(kind,value)
    return true
end
function Actions:_showRecentNotebooks()
    local actions={}
    local Thumbnail=require("thumbnail")
    for _,rel in ipairs(Recents.list(Library.relOf(self.document.path))) do
        actions[#actions+1]={icon="notebook.open",preview_source=Library.abs(rel),
            preview=Thumbnail.cached(Library.abs(rel)),text=rel:gsub("%.scribe$",""),
            callback=function() self:_requestNotebook("recent",rel) end}
    end
    if #actions==0 then
        UIManager:show(InfoMessage:new{text=_("No other recent notebooks.")});return
    end
    local screen=require("device").screen
    local row_height=math.min(screen:scaleBySize(88),
        math.floor((screen:getHeight()-screen:scaleBySize(100))/#actions))
    local menu=showActions(_("Recent notebooks"),actions,nil,row_height)
    local index=0
    local function step()
        if menu._menu_freed then return end
        index=index+1
        local action=actions[index]
        if not action then return end
        local row=menu.action_rows[index].row
        if not action.preview then
            local path=Thumbnail.get(action.preview_source,row.preview_size,row.preview_size,1860,2480)
            if path then
                action.preview=path
                row:setPreview(path)
                UIManager:setDirty(menu,"ui",menu.panel.dimen)
            end
        end
        require("safe").later("recent:thumbnail",step)
    end
    require("safe").later("recent:thumbnail",step)
end
function Actions:_toggleDiagnostics()
    local ok,err=Diagnostics.set(self.canvas,not self.canvas.debug_log_path)
    if not ok then UIManager:show(InfoMessage:new{text=tostring(err)});return end
    UIManager:show(InfoMessage:new{text=Diagnostics.enabled
        and (_("Input logging is active. Reproduce the problem on a test page, then stop logging and attach:").."\n\n"..Diagnostics.path())
        or _("Input logging stopped. Existing log files have been kept.")})
end
function Actions:_setPaperOption(key,value)
    self:_finishInteraction()
    local options=self.document.paper_options or {}
    local updated={spacing=options.spacing,gray=options.gray};updated[key]=value
    self.document.paper_options=require("paperoptions").normalize(updated)
    self.document.dirty=true
    self.canvas:_clearZoomCache()
    self.canvas.background_cache_key=nil
    self:_fullRepaint()
    UIManager:unschedule(self.canvas.autosave_cb)
    UIManager:scheduleIn(2.5,self.canvas.autosave_cb)
end
function Actions:_showPaperOptions()
    local actions={}
    for _index,value in ipairs({4,5.5,8,11}) do
        actions[#actions+1]={icon="notebook.page",section=#actions==0 and _("Spacing") or nil,text=tostring(value).." mm",
            selected=function() return self.document.paper_options and self.document.paper_options.spacing==value end,
            callback=function() self:_setPaperOption("spacing",value);self:_showPaperOptions() end}
    end
    for i,option in ipairs({{224,_("Light")},{176,_("Medium")},{112,_("Dark")}}) do
        local gray,label=option[1],option[2]
        actions[#actions+1]={icon="notebook.page",section=i==1 and _("Ruling tone") or nil,text=label,
            selected=function() return self.document.paper_options and self.document.paper_options.gray==gray end,
            callback=function() self:_setPaperOption("gray",gray);self:_showPaperOptions() end}
    end
    actions[#actions+1]={icon="notebook.refresh",text=_("Default paper settings"),callback=function()
        self:_setPaperOption("spacing",nil);self:_setPaperOption("gray",nil)
    end}
    showActions(_("Paper spacing and tone"),actions)
end
function Actions:_showNotebookMenu()
    self:_finishInteraction()
    self.settings_button:setSelected(true)
    for _,button in ipairs(self.tool_buttons) do button:setSelected(false) end
    self:_refreshToolbar()
    showActions(self.title or _("Notebook"),{
        {icon="notebook.page",section=_("Notebooks"),pair=true,text=_("New notebook"),callback=function() self:_requestNotebook("new") end},
        {icon="notebook.export",text=_("Open PDF"),callback=function() self:_requestNotebook("pdf") end},
        {icon="notebook.open",pair=true,text=_("Open another notebook"),callback=function() self:_requestNotebook("library") end},
        {icon="notebook.open",text=_("Recent notebooks"),callback=function() self:_showRecentNotebooks() end},
        {icon="notebook.page",section=_("Page"),pair=true,text=_("Paper spacing and tone"),callback=function() self:_showPaperOptions() end},
        {icon="notebook.image",text=_("Insert image"),callback=function() self:_insertImage() end},
        {icon="appbar.settings",section=_("Settings"),text=_("Tool settings"),callback=function() self:_showToolSettings() end},
        {icon="notebook.refresh",text=self.canvas.debug_log_path and _("Stop input log") or _("Start input log"),
            callback=function() self:_toggleDiagnostics() end},
    },function()
        self.settings_button:setSelected(false)
        for i,button in ipairs(self.tool_buttons) do
            button:setSelected(self.canvas.tool==require("notebooktoolbar").tools[i].tool)
        end
        if not self.closed then self:_refreshToolbar() end
    end)
end
function Actions:_insertImage()
    self:_finishInteraction()
    if self.canvas.zoom>1 then self:_toggleZoom() end
    local PathChooser=require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{select_directory=false,
        path=G_reader_settings:readSetting("notebook_image_folder") or "/mnt/us/documents",
        onConfirm=function(path)
            local image,err=require("imageobject").import(path,self.canvas.content)
            if not image then UIManager:show(InfoMessage:new{text=tostring(err)});return end
            G_reader_settings:saveSetting("notebook_image_folder",path:match("^(.*)/"))
            self.document:addStroke(image)
            self:_fullRepaint()
            self.canvas:_showLassoMenu({image})
            UIManager:unschedule(self.canvas.autosave_cb)
            UIManager:scheduleIn(2.5,self.canvas.autosave_cb)
        end})
end
return Actions
