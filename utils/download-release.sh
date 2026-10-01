#!/bin/sh
# Download an official stable Notebook ZIP. Does not install or restart KOReader.
set -eu
version=1.5.0
runtime=${NOTEBOOK_KOREADER_DIR:-/mnt/us/koreader}
output=/mnt/us/Downloads
while [ "$#" -gt 0 ]; do
    case "$1" in
        --runtime|--output)
            [ "$#" -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }
            case "$1" in --runtime) runtime=$2;; --output) output=$2;; esac
            shift 2;;
        --help|-h)
            echo "Usage: $0 [1.5.0] [--runtime /mnt/us/koreader] [--output /mnt/us/Downloads]"
            echo "Downloads and verifies a stable GitHub release; never installs it."
            exit 0;;
        -*) echo "Unknown option: $1" >&2; exit 2;;
        *) version=${1#v}; shift;;
    esac
done
printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || {
    echo "Only official stable versions such as 1.5.0 are accepted." >&2; exit 2;
}
[ -x "$runtime/luajit" ] || { echo "KOReader runtime missing: $runtime" >&2; exit 1; }
mkdir -p "$output"
output=$(cd "$output" && pwd -P)
runtime=$(cd "$runtime" && pwd -P)
work=$(mktemp -d "$output/.notebook-download.XXXXXX")
trap 'rm -rf -- "$work"' EXIT HUP INT TERM
fetch() {
    if [ -f "$runtime/data/ca-bundle.crt" ]; then
        curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 10 \
            --max-time 120 --max-filesize 8388608 --cacert "$runtime/data/ca-bundle.crt" "$@"
    else
        curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 10 \
            --max-time 120 --max-filesize 8388608 "$@"
    fi
}
tag=v$version
name=notebook.koplugin-$tag.zip
base=https://github.com/pierspad/notebook.koplugin/releases/download/$tag
fetch -o "$work/release.json" "https://api.github.com/repos/pierspad/notebook.koplugin/releases/tags/$tag"
fetch -o "$work/package.zip" "$base/$name"
cat > "$work/verify.lua" <<'LUA'
require("setupkoenv")
local json=require("json")
local function read(path)
    local file=assert(io.open(path,"rb"));local data=assert(file:read("*a"));assert(file:close());return data
end
local tag,name,api,zip=arg[1],arg[2],arg[3],arg[4]
local release=json.decode(read(api))
assert(release.tag_name==tag and release.draft==false and release.prerelease==false,"Not an official stable release")
local asset
for _,item in ipairs(release.assets or {}) do
    if item.name==name then assert(not asset,"Duplicate asset");asset=item end
end
assert(asset and asset.state=="uploaded","Release ZIP missing")
assert(asset.browser_download_url=="https://github.com/pierspad/notebook.koplugin/releases/download/"..tag.."/"..name,"Unexpected asset URL")
assert(type(asset.size)=="number" and asset.size>0 and asset.size<=8388608,"Invalid asset size")
local digest=type(asset.digest)=="string" and asset.digest:match("^sha256:([0-9a-f]+)$")
assert(digest and #digest==64,"GitHub SHA-256 missing")
local file=assert(io.open(zip,"rb"))
local hash=require("ffi/sha2").sha256()
local size=0
while true do
    local chunk,err=file:read(65536)
    assert(not err,err)
    if not chunk then break end
    size=size+#chunk;assert(size<=8388608,"ZIP too large");hash(chunk)
end
assert(file:close())
assert(size==asset.size and hash()==digest,"ZIP checksum/size mismatch")
print("Verified official stable release "..tag)
LUA
(cd "$runtime" && ./luajit "$work/verify.lua" "$tag" "$name" "$work/release.json" "$work/package.zip")
mv -f "$work/package.zip" "$output/$name"
printf 'Downloaded: %s\n' "$output/$name"
