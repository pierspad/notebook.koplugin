-- Gallery export/share jobs and progress; gallery.lua owns navigation and selection.
local Document = require("document")
local Export = require("export")
local ExportProgress = require("exportprogress")
local Xopp = require("xopp")
local InfoMessage = require("ui/widget/infomessage")
local Library = require("library")
local UIManager = require("ui/uimanager")
local _ = require("i18n")
local Safe = require("safe")
local Share = require("share")
local lfs = require("libs/libkoreader-lfs")
local T = require("ffi/util").template
local NOTICE_SECONDS = 3

return function(Gallery, isExport, notebooksOnly)
--[[--
Hands what has been chosen to LocalSend.

A notebook means nothing to a phone -- .scribe is this plugin's own format -- so
it is rendered to a PDF on the way out. An exported PDF is already readable and
goes as it is.

One PDF on its own is sent straight from where it lies. Anything else is staged
into a directory and the directory is what goes: LocalSend's send flow takes one
path, and choosing the target device once per notebook would not be sending a
selection so much as sending several times over.

The staged copies are meant to be temporary and are not deleted here; see
share.lua for why, and for what does delete them.

Rendered one per tick, like the Export action and for the same reason: a dozen
notebooks back to back would freeze the screen for the whole run.
--]]
function Gallery:_shareMany(chosen, format, prepared)
    self:_endSelection()

    -- Let LocalSend discover devices first and own the format switch in that
    -- screen. Rendering starts only after a target and format are chosen.
    if not format and #notebooksOnly(chosen)>0 then
        local selected=G_reader_settings:readSetting("notebook_share_format") == "xopp" and "xopp" or "pdf"
        return self.on_share(nil,{
            selector_options={
                selected=selected,
                values={{value="pdf",text=_("PDF")},{value="xopp",text=_("XOPP")}},
                on_change=function(value)
                    G_reader_settings:saveSetting("notebook_share_format",value)
                end,
            },
            prepare=function(value,callback)
                G_reader_settings:saveSetting("notebook_share_format",value)
                self:_shareMany(chosen,value,callback)
            end,
        })
    end

    if #chosen == 1 and isExport(chosen[1])
            and not (chosen[1].is_xopp
                and lfs.attributes(Xopp.backgroundPath(chosen[1].path), "mode") == "file") then
        if prepared then return prepared(chosen[1].path) end
        return self.on_share(chosen[1].path)
    end

    local staging = Share.stagingDir()
    if not staging then
        if prepared then return prepared(nil,_("There is nowhere to prepare the files for sending.")) end
        return UIManager:show(InfoMessage:new{
            text = _("There is nowhere to prepare the files for sending."),
            timeout = NOTICE_SECONDS,
        })
    end

    local working = InfoMessage:new{
        text = #chosen == 1 and T(_("Preparing '%1'…"), chosen[1].name)
                             or T(_("Preparing %1 items…"), #chosen),
    }
    UIManager:show(working)

    local i, done, failed, last_out, multiple_files = 0, 0, 0, nil, false
    format=format or (G_reader_settings:readSetting("notebook_share_format") == "xopp" and "xopp" or "pdf")
    local function step()
        i = i + 1
        local item = chosen[i]

        if not item then
            UIManager:close(working)
            if done == 0 then
                Library.deleteTree(staging)
                if prepared then return prepared(nil,_("Nothing could be prepared for sending.")) end
                return UIManager:show(InfoMessage:new{text=_("Nothing could be prepared for sending."),timeout=NOTICE_SECONDS})
            end
            if failed > 0 then
                UIManager:show(InfoMessage:new{
                    text = T(_("Sending %1; %2 could not be read."), done, failed),
                    timeout = NOTICE_SECONDS,
                })
            end
            -- One file staged on its own goes as a file rather than as a
            -- directory holding one thing, which is what the other device
            -- would otherwise be asked to accept.
            local ready=done == 1 and not multiple_files and last_out or staging
            if prepared then return prepared(ready) end
            return self.on_share(ready)
        end

        local out = staging .. "/" .. item.name .. "." .. (item.extension or format)
        local ok
        if isExport(item) then
            ok = Library.copyFile(item.path, out)
            if ok and item.is_xopp then
                local background = Xopp.backgroundPath(item.path)
                if lfs.attributes(background, "mode") == "file" then
                    ok = Library.copyFile(background, Xopp.backgroundPath(out))
                    multiple_files = true
                    if not ok then os.remove(out) end
                end
            end
        else
            local doc = Document:new(item.path)
            if doc:load() then
                local cached=Share.cachedExport(item.path,item.name,format)
                local cached_extra=cached and Xopp.backgroundPath(cached)
                if cached and lfs.attributes(cached,"mode")=="file"
                        and (format~="xopp" or not doc:hasPDFBackgrounds()
                            or lfs.attributes(cached_extra,"mode")=="file") then
                    ok=Library.copyFile(cached,out)
                    if ok and format=="xopp" and lfs.attributes(cached_extra,"mode")=="file" then
                        ok=Library.copyFile(cached_extra,Xopp.backgroundPath(out))
                        multiple_files=true
                        if not ok then os.remove(out) end
                    end
                elseif cached then
                    local extra
                    if format=="xopp" then ok,extra=Xopp.toXOPP(doc,cached)
                    else ok=Export.toPDF(doc,cached) end
                    if ok then
                        ok=Library.copyFile(cached,out)
                        if ok and extra then
                            ok=Library.copyFile(extra,Xopp.backgroundPath(out))
                            multiple_files=true
                            if not ok then os.remove(out) end
                        end
                    end
                elseif format=="xopp" then
                    local extra
                    ok,extra=Xopp.toXOPP(doc,out)
                    if extra then multiple_files=true end
                else ok=Export.toPDF(doc,out) end
            end
        end
        if ok then
            done, last_out = done + 1, out
        else
            failed = failed + 1
        end

        Safe.later("gallery:share", step)
    end

    -- A tick later, so the message is on screen before the first render blocks.
    Safe.later("gallery:share", step)
end

--[[--
Exports several notebooks, one per tick.

Rendering a notebook to PDF takes long enough to notice, and a dozen of them
back to back would freeze the panel for the whole run with nothing to show for
it. One per tick keeps the screen answering, and the message says which one is
being worked on so the wait is legible rather than mysterious.
--]]
function Gallery:_exportMany(notebooks, format)
    self:_endSelection()
    format=format or "pdf"

    local working
    if format ~= "pdf" then
        working = InfoMessage:new{
            text = #notebooks == 1 and T(_("Exporting '%1'…"), notebooks[1].name)
                                    or T(_("Exporting %1 notebooks…"), #notebooks),
        }
        UIManager:show(working)
    end

    local i, done, failed, last_path, last_extra, cancelled = 0, 0, 0, nil, nil, false
    local progress
    local function finish()
        if working then UIManager:close(working) end
        if progress then progress:close(); progress = nil end
        self:_rebuild()
        if cancelled then
            return UIManager:show(InfoMessage:new{
                text = _("Export cancelled."),
                timeout = NOTICE_SECONDS,
            })
        end
        local text
        if failed == 0 and done == 1 and last_extra then
            text = T(_("Xournal++ needs both files. Keep them together:\n%1\n%2"),
                last_path, last_extra)
        elseif failed == 0 and done == 1 then
            text = T(_("Exported to:\n%1"), last_path)
        elseif failed == 0 then
            text = T(_("Exported %1 notebooks."), done)
        else
            text = T(_("Exported %1 of %2; %3 could not be read."),
                done, #notebooks, failed)
        end
        UIManager:show(InfoMessage:new{text=text,timeout=NOTICE_SECONDS})
    end

    local function step()
        i = i + 1
        local item = notebooks[i]
        if not item then return finish() end

        local doc = Document:new(item.path)
        if doc:load() then
            local out = Library.abs(self.folder) .. "/" .. item.name .. "." .. format
            if format == "pdf" then
                local job = Export.beginPDF(doc, out)
                if not job then
                    failed = failed + 1
                    return Safe.later("gallery:export", step)
                end
                progress = ExportProgress:new{
                    title = T(_("Exporting '%1'…"), item.name),
                    total = job.total,
                    on_cancel = function() job:cancel() end,
                }
                progress:show()
                progress:update(job.page, job.page_count, job.phase,
                    job.completed, job.total)
                local function pageStep()
                    local state = job:step()
                    if state == "working" then
                        progress:update(job.page, job.page_count, job.phase,
                            job.completed, job.total)
                        return Safe.later("gallery:export-page", pageStep)
                    end
                    progress:close()
                    progress = nil
                    if state == "done" then
                        done, last_path = done + 1, out
                    elseif state == "cancelled" then
                        cancelled = true
                        return finish()
                    else
                        failed = failed + 1
                    end
                    Safe.later("gallery:export", step)
                end
                return Safe.later("gallery:export-page", pageStep)
            end
            local ok,extra = Xopp.toXOPP(doc,out)
            if ok then
                done, last_path, last_extra = done + 1, out, extra
            else
                failed = failed + 1
            end
        else
            failed = failed + 1
        end
        Safe.later("gallery:export", step)
    end

    Safe.later("gallery:export", step)
end

end
