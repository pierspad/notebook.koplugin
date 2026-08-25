#!/usr/bin/env bash
#
# Installs the LocalSend plugin onto a Kindle running KOReader.
#
# This is somebody else's plugin -- https://github.com/kaikozlov/localsend.koplugin
# -- and nothing of it lives in this repo. It has a Go backend, so the plugin is
# a compiled binary plus its Lua, and only the published releases carry that
# binary: the source checkout next door cannot simply be copied onto a device.
# So this fetches the release for the device's architecture, keeps it in
# .localsend-cache/, and copies it across.
#
# It is separate from deploy.sh on purpose. Notebook does not depend on this
# plugin -- with it installed a Send action appears in the gallery, without it
# nothing does -- and installing it is a decision, not a build step.
# Run both together with:
#
#   tools/deploy.sh <target> --with-localsend
#
# Or on its own, exactly like deploy.sh:
#
#   tools/deploy-localsend.sh /mnt/kindle
#   tools/deploy-localsend.sh root@192.168.1.42
#
#   --port N        use this port alone, instead of trying 2222 and 22
#   --arch NAME     armv7 (default), arm64, or arm-legacy
#   --version TAG   a specific release, instead of the latest
#   --restart       restart KOReader once the files are in place
#
# armv7 is the right answer for every Kindle, including the Scribe: the
# userland is 32-bit whatever the silicon can do. arm64 is for the reMarkable
# Paper Pro, and arm-legacy for devices too old for armv7.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for env_file in "$SCRIPT_DIR/kindle.env" "$SCRIPT_DIR/.kindle.env"; do
    if [ -f "$env_file" ]; then
        # shellcheck source=/dev/null
        source "$env_file"
        break
    fi
done

REPO="kaikozlov/localsend.koplugin"
PLUGIN_NAME="localsend.koplugin"
CACHE="$SCRIPT_DIR/.localsend-cache"

ARCH="${LOCALSEND_ARCH:-armv7}"
VERSION="${LOCALSEND_VERSION:-}"
RESTART=0
PORT=""
ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --restart) RESTART=1 ;;
        --port) PORT="$2"; shift ;;
        --arch) ARCH="$2"; shift ;;
        --version) VERSION="$2"; shift ;;
        -h|--help)
            sed -n '2,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) ARGS+=("$1") ;;
    esac
    shift
done

TARGET="${ARGS[*]:-}"

if [ -z "$TARGET" ]; then
    if [ -n "${KINDLE_IP:-}" ]; then
        TARGET="${KINDLE_USER:-root}@$KINDLE_IP"
        echo "==> using default target from kindle.env: $TARGET"
    else
        echo "usage: $0 <mount-point|ssh-host> [--arch NAME] [--port N] [--restart]" >&2
        exit 1
    fi
fi

case "$TARGET" in
    mtp:*|gphoto2:*|kio:*)
        echo "error: that is a file-manager address (MTP), not a directory." >&2
        echo "       See tools/deploy.sh --help; the same applies here." >&2
        exit 1
        ;;
esac

for tool in curl unzip; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "error: $tool is needed to fetch and unpack the release" >&2
        exit 1
    }
done

# Fetching the release ---------------------------------------------------------
#
# Kept in a cache directory rather than downloaded every run: the zip is several
# megabytes of compiled Go, it does not change between deploys, and reinstalling
# after wiping a device should not need the network at all.

if [ -z "$VERSION" ]; then
    echo "==> asking GitHub for the latest release"
    VERSION="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
        | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
    if [ -z "$VERSION" ]; then
        echo "error: could not read the latest version from GitHub" >&2
        echo "       pass one yourself with --version, e.g. --version v1.4.4" >&2
        exit 1
    fi
    echo "    latest is $VERSION"
fi

ZIP="$CACHE/localsend-koplugin-$ARCH-$VERSION.zip"
URL="https://github.com/$REPO/releases/download/$VERSION/localsend-koplugin-$ARCH.zip"

if [ -f "$ZIP" ]; then
    echo "==> using the copy already in .localsend-cache ($VERSION, $ARCH)"
else
    echo "==> downloading $URL"
    mkdir -p "$CACHE"
    # To a temporary name first, so an interrupted download is not left behind
    # looking like a complete one.
    if ! curl -fL --progress-bar -o "$ZIP.part" "$URL"; then
        rm -f "$ZIP.part"
        echo "error: download failed -- is $VERSION published for $ARCH?" >&2
        echo "       see https://github.com/$REPO/releases" >&2
        exit 1
    fi
    mv "$ZIP.part" "$ZIP"
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
unzip -q "$ZIP" -d "$STAGE"

# The zip may hold the plugin directory itself or contain its files directly;
# find whichever it is rather than assuming.
if [ -d "$STAGE/$PLUGIN_NAME" ]; then
    SRC="$STAGE/$PLUGIN_NAME"
elif [ -f "$STAGE/main.lua" ]; then
    SRC="$STAGE"
else
    SRC="$(find "$STAGE" -maxdepth 3 -name main.lua -print -quit)"
    SRC="${SRC%/main.lua}"
fi

if [ -z "$SRC" ] || [ ! -f "$SRC/main.lua" ]; then
    echo "error: no plugin found inside $ZIP" >&2
    exit 1
fi

# Installing -------------------------------------------------------------------

deploy_mounted() {
    local root="$1"
    local plugins="$root/koreader/plugins"

    if [ ! -d "$root/koreader" ]; then
        echo "error: no koreader directory under $root" >&2
        exit 1
    fi

    echo "==> installing to $plugins/$PLUGIN_NAME"
    rm -rf "${plugins:?}/$PLUGIN_NAME"
    mkdir -p "$plugins/$PLUGIN_NAME"
    cp -r "$SRC/." "$plugins/$PLUGIN_NAME/"
    sync
    echo "    done -- eject the Kindle, then restart KOReader"
}

port_open() {
    local host="${1#*@}"
    timeout 3 bash -c "exec 3<>/dev/tcp/${host}/$2" 2>/dev/null
}

deploy_ssh() {
    local host="$1"
    local remote="/mnt/us/koreader/plugins"

    local ports=()
    if [ -n "$PORT" ]; then
        ports=("$PORT")
    elif [ -n "${KINDLE_PORTS:-}" ]; then
        # shellcheck disable=SC2206
        ports=($KINDLE_PORTS)
    else
        ports=(2222 22)
    fi

    local port=""
    for candidate in "${ports[@]}"; do
        echo "==> checking $host:$candidate"
        if ! port_open "$host" "$candidate"; then
            echo "    nothing listening"
            continue
        fi
        if ssh -p "$candidate" -o ConnectTimeout=10 "$host" "test -d $remote"; then
            port="$candidate"
            break
        fi
        echo "    answered, but $remote is not there"
    done

    if [ -z "$port" ]; then
        echo "error: no KOReader found on $host (tried ${ports[*]})" >&2
        exit 1
    fi

    local SSH=(ssh -p "$port" -o ConnectTimeout=10)
    local SCP=(scp -P "$port" -o ConnectTimeout=10 -q -r)

    echo "==> installing to $host:$remote/$PLUGIN_NAME"
    "${SSH[@]}" "$host" "rm -rf $remote/$PLUGIN_NAME && mkdir -p $remote/$PLUGIN_NAME"
    "${SCP[@]}" "$SRC/." "$host:$remote/$PLUGIN_NAME/"

    # The binary loses its permissions on the way across often enough to be
    # worth fixing unconditionally: without it the plugin loads, shows its menu,
    # and fails every transfer.
    "${SSH[@]}" "$host" "chmod +x $remote/$PLUGIN_NAME/localsend* 2>/dev/null || true"

    if ! "${SSH[@]}" "$host" "test -f $remote/$PLUGIN_NAME/main.lua"; then
        echo "error: the plugin does not appear to have landed" >&2
        exit 1
    fi
    echo "    files in place"

    if [ "$RESTART" -eq 1 ]; then
        echo "==> restarting KOReader"
        "${SSH[@]}" "$host" "killall -TERM reader.lua 2>/dev/null || true"
        sleep 3
        "${SSH[@]}" "$host" \
            "cd /mnt/us/koreader && (setsid ./koreader.sh >/dev/null 2>&1 &)"
        local up=0
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            sleep 3
            if "${SSH[@]}" "$host" "pgrep -f reader.lua >/dev/null" 2>/dev/null; then
                up=1
                break
            fi
        done
        if [ "$up" -eq 1 ]; then
            echo "    KOReader is back up"
        else
            echo "    WARNING: KOReader did not come back -- start it from the device" >&2
        fi
    else
        echo "    done -- restart KOReader on the device to load the plugin"
    fi
}

if [ -d "$TARGET" ]; then
    deploy_mounted "$TARGET"
else
    deploy_ssh "$TARGET"
fi

cat <<'EOF'

LocalSend lives in:  Menu -> Network -> LocalSend
With it installed, holding a notebook in the gallery offers Send.

To uninstall, delete koreader/plugins/localsend.koplugin.
EOF
