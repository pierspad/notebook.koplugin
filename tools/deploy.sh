#!/usr/bin/env bash
#
# Installs the Notebook plugin onto a Kindle running KOReader.
#
# This script only ever writes one directory: koreader/plugins/notebook.koplugin
# -- two, with --with-localsend, and the second one is as easily deleted as the
# first. It touches nothing else: not your books, not your settings, not
# KOReader itself, so uninstalling is just deleting those directories, and
# there is nothing here that can leave the device in a broken state.
#
# Two ways to use it:
#
#   tools/deploy.sh /mnt/kindle           copy to a Kindle mounted as a real disk
#   tools/deploy.sh root@192.168.1.42     copy over SSH
#
# Or through the Makefile, which is the same thing with the target remembered:
#
#   make deploy TARGET=root@192.168.1.42 FLAGS=--restart
#
# SSH is the practical option on KDE/GNOME, where the Kindle usually appears
# over MTP -- an address inside the file manager rather than a directory, which
# no script can write to.
#
# There are two SSH servers a Kindle might be answering on, and which one you
# get depends on how the device is set up: KOReader's own (Menu -> Tools -> SSH)
# listens on 2222, while a Kindle with USBNetwork installed answers on 22. Both
# are tried, in that order, and each is given a moment to answer before moving
# on -- so pointing this at a device that is asleep, or at the wrong address,
# comes back with an error instead of sitting there.
#
#   --port N          use this port alone, instead of trying 2222 and 22
#   --restart         restart KOReader once the files are in place
#   --with-localsend  also run tools/deploy-localsend.sh against the same device
#
# LocalSend is somebody else's plugin and is not part of this repo. Notebook
# does not need it: with it installed a Send action appears in the gallery,
# without it nothing does. --with-localsend is there so that testing both takes
# one command; see tools/deploy-localsend.sh --help.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for env_file in "$SCRIPT_DIR/kindle.env" "$SCRIPT_DIR/.kindle.env"; do
    if [ -f "$env_file" ]; then
        # shellcheck source=/dev/null
        source "$env_file"
        break
    fi
done

# The sources are `lua/`; on a device they are `notebook.koplugin`. The staging
# copy is what gets sent, so that the directory lands with the name KOReader
# takes the plugin's own name from.
PLUGIN_NAME="notebook.koplugin"
PLUGIN_DIR="$SCRIPT_DIR/build/$PLUGIN_NAME"

RESTART=0
PORT=""
WITH_LOCALSEND=0
ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --restart) RESTART=1 ;;
        --port) PORT="$2"; shift ;;
        --with-localsend) WITH_LOCALSEND=1 ;;
        -h|--help)
            sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) ARGS+=("$1") ;;
    esac
    shift
done

# Paths with spaces are common (removable media is often labelled with the
# device name), and an unquoted one arrives here split into several arguments.
# Rejoining them is friendlier than failing on something that looks correct.
TARGET="${ARGS[*]:-}"

if [ -z "$TARGET" ]; then
    if [ -n "${KINDLE_IP:-}" ]; then
        TARGET="${KINDLE_USER:-root}@$KINDLE_IP"
        echo "==> using default target from kindle.env: $TARGET"
    else
        echo "usage: $0 <mount-point|ssh-host> [--port N] [--restart]" >&2
        exit 1
    fi
fi

# A KDE/GNOME "mtp:/..." address is not a filesystem path -- nothing outside the
# file manager can read or write it -- so say so plainly instead of failing later
# with a confusing hostname error.
case "$TARGET" in
    mtp:*|gphoto2:*|kio:*)
        cat >&2 <<'EOF'
error: that is a file-manager address (MTP), not a directory this script can use.

MTP is not a real filesystem, so nothing outside Dolphin can write to it.
Two options:

  1. SSH -- the better one, see README. KOReader has a built-in SSH server.
  2. Run `make package` and copy the built notebook.koplugin out of build/
     by hand in Dolphin, into koreader/plugins/ on the Kindle.
EOF
        exit 1
        ;;
esac

if [ ! -d "$PLUGIN_DIR" ]; then
    echo "error: cannot find $PLUGIN_DIR" >&2
    exit 1
fi

# Refuse to ship a plugin whose logic is failing its own tests, and build the
# staging copy from the sources so that what goes across is what is in the tree.
echo "==> building"
make -C "$SCRIPT_DIR" verify package >/dev/null || {
    echo "error: verification failed, refusing to deploy" >&2
    exit 1
}
rm -rf "$PLUGIN_DIR"
mkdir -p "$PLUGIN_DIR"
cp -r "$SCRIPT_DIR/lua/." "$PLUGIN_DIR/"
rm -rf "$PLUGIN_DIR/spec"
echo "    tests pass"

deploy_mounted() {
    local root="$1"
    local plugins="$root/koreader/plugins"

    if [ ! -d "$root/koreader" ]; then
        echo "error: no koreader directory under $root" >&2
        echo "       is the Kindle mounted there?" >&2
        exit 1
    fi

    echo "==> installing to $plugins/$PLUGIN_NAME"
    rm -rf "${plugins:?}/$PLUGIN_NAME"
    mkdir -p "$plugins"
    cp -r "$PLUGIN_DIR" "$plugins/"
    sync
    echo "    done -- eject the Kindle, then restart KOReader"
}

# True if something is listening on host:port. A plain TCP connect, so it costs
# nothing and cannot stop to ask for a password: an ssh probe against a port
# nobody is serving waits for its own timeout, and against one that wants a
# password it sits at a prompt, which is indistinguishable from a hang.
port_open() {
    local host="${1#*@}"
    timeout 3 bash -c "exec 3<>/dev/tcp/${host}/$2" 2>/dev/null
}

deploy_ssh() {
    local host="$1"
    local remote="/mnt/us/koreader/plugins"

    # Whichever of the ports is both answering and has KOReader behind it. The
    # second test matters as much as the first: something else on the network
    # can be listening on 22 without being the Kindle.
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
        echo "       is the device awake, and is one of these running?" >&2
        echo "         * KOReader's SSH server -- Menu -> Tools -> SSH (port 2222)" >&2
        echo "         * USBNetwork, which gives you the ordinary sshd (port 22)" >&2
        exit 1
    fi

    local SSH=(ssh -p "$port" -o ConnectTimeout=10)
    local SCP=(scp -P "$port" -o ConnectTimeout=10 -q -r)

    echo "==> installing to $host:$remote/$PLUGIN_NAME"
    "${SSH[@]}" "$host" "rm -rf $remote/$PLUGIN_NAME"
    "${SCP[@]}" "$PLUGIN_DIR" "$host:$remote/"

    if ! "${SSH[@]}" "$host" "test -f $remote/$PLUGIN_NAME/main.lua"; then
        echo "error: the plugin does not appear to have landed" >&2
        exit 1
    fi
    echo "    files in place"

    if [ "$RESTART" -eq 1 ]; then
        echo "==> restarting KOReader"
        # Terminating reader.lua on a Kindle does NOT bring it back -- there is
        # no supervising loop the way there is under the emulator, so a kill on
        # its own just leaves the device sitting at the home screen with the
        # plugin never reloaded. Relaunch it explicitly.
        "${SSH[@]}" "$host" "killall -TERM reader.lua 2>/dev/null || true"
        sleep 3
        "${SSH[@]}" "$host" \
            "cd /mnt/us/koreader && (setsid ./koreader.sh >/dev/null 2>&1 &)"

        # Confirm it actually came back rather than assuming it did.
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

# LocalSend first, so that our own --restart at the end brings both plugins up
# together. Its own --restart is deliberately not passed on: restarting twice
# would mean waiting through the whole start-up sequence for nothing.
if [ "$WITH_LOCALSEND" -eq 1 ]; then
    localsend_args=("$TARGET")
    [ -n "$PORT" ] && localsend_args+=(--port "$PORT")
    "$SCRIPT_DIR/tools/deploy-localsend.sh" "${localsend_args[@]}"
    echo
fi

if [ -d "$TARGET" ]; then
    deploy_mounted "$TARGET"
else
    deploy_ssh "$TARGET"
fi

cat <<'EOF'

The notebooks live in:  Menu -> Tools (wrench) -> page 2 -> More tools -> Notebook
They are saved under:   koreader/notebook/

To uninstall, delete koreader/plugins/notebook.koplugin. Nothing else changed.
EOF
