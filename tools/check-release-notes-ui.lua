-- Native updater offer, Markdown conversion and HTML layout in disposable storage.
-- Run from KOReader: ./luajit THIS PLUGIN_LUA TEMP_DIRECTORY
require("setupkoenv")
G_defaults=require("luadefaults"):open()
local tmp=assert(require("ffi/util").realpath(assert(arg[2])))
G_reader_settings=require("luasettings"):open(tmp.."/settings.lua")
local Device=require("device")
require("document/canvascontext"):init(Device)
local load=dofile(arg[1].."/loader.lua")(arg[1])
local BB=require("ffi/blitbuffer")
local screen=Device.screen
local bb=BB.new(screen:getWidth(),screen:getHeight(),BB.TYPE_BB8)
screen.bb=bb
local UI=require("ui/uimanager")
local offered
UI.show=function(_,widget) if widget.text_format then offered=widget end end
require("ui/network/manager").runWhenOnline=function(_,callback) callback() end
local notes="## [9.9.9](https://github.com/pierspad/notebook.koplugin/compare/v1.6.1...v9.9.9) (2026-10-02)\n\n"
    .."### Bug Fixes\n\n* **Readable notes** with [one link label](https://example.org/changes).\n"
    .."* Faster erasing and `code` formatting.\n\n> A quoted paragraph.\n"
local url="https://github.com/pierspad/notebook.koplugin/releases/download/v9.9.9/notebook.koplugin-v9.9.9.zip"
local data={tag_name="v9.9.9",draft=false,prerelease=false,body=notes,assets={{
    name="notebook.koplugin-v9.9.9.zip",state="uploaded",size=123,
    browser_download_url=url,digest="sha256:"..string.rep("a",64)}}}
load("updatetransport").fetch=function(_,_,_,_,callback)
    local path=tmp.."/fixture.json"
    local file=assert(io.open(path,"w"));file:write(require("json").encode(data));file:close()
    callback(path)
end
load("updater").check(true)
assert(offered and offered.text_format=="md" and not offered.is_txt,"offer is still plain text")
local html=offered.scroll_widget.html_body
assert(html and html:find("<h2",1,true) and html:find("<h3",1,true),"headings not rendered")
assert(html:find("<strong>",1,true) and html:find("<li>",1,true),"inline/list formatting lost")
assert(html:find('href="https://example.org/changes"',1,true),"Markdown link not converted")
assert(not html:find("###",1,true) and not html:find("[9.9.9]",1,true),"raw Markdown leaked")
offered:paintTo(bb,0,0)
bb:writePNG(tmp.."/release-notes.png")
offered:free();bb:free()
print("Native updater Markdown: private callback, headings, bold, lists, code, links and real HTML render passed")
