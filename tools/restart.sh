#!/usr/bin/env bash
#
# Restarts KOReader on a Kindle over SSH, without rebooting the device.
#
# For when KOReader has stopped answering: a plugin caught in a loop takes the
# event loop with it, and from the outside that looks exactly like a dead
# Kindle. It is not. KOReader's SSH server is dropbear, running as its own
# process, so it keeps answering while the Lua loop is stuck -- which means the
# device can be recovered over the network. Killing reader.lua and starting it
# again takes a few seconds, and the notebooks come back as last saved.
#
# Worth turning SSH on and leaving it on for exactly this reason: it cannot be
# started from a device that has already frozen.
#
#   ./restart.sh root@192.168.1.42
#
# Ports are tried the same way deploy.sh tries them: KOReader's own SSH server
# on 2222 first, then USBNetwork's sshd on 22.
#
#   --port N    use this port alone
#   --log       fetch the plugin's error log first, if there is one
#   --kill      stop KOReader and leave it stopped
#
# If SSH itself cannot be reached, nothing here can help and the device really
# does have to be restarted by hand -- the script says so rather than hanging.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for env_file in "$SCRIPT_DIR/kindle.env" "$SCRIPT_DIR/.kindle.env"; do
    if [ -f "$env_file" ]; then
        # shellcheck source=/dev/null
        source "$env_file"
        break
    fi
done

PORT=""
FETCH_LOG=0
KILL_ONLY=0
ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --port) PORT="$2"; shift ;;
        --log) FETCH_LOG=1 ;;
        --kill) KILL_ONLY=1 ;;
        -h|--help)
            sed -n "2,26p" "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) ARGS+=("$1") ;;
    esac
    shift
done

HOST="${ARGS[*]:-}"
if [ -z "$HOST" ]; then
    if [ -n "${KINDLE_IP:-}" ]; then
        HOST="${KINDLE_USER:-root}@$KINDLE_IP"
        echo "==> using default host from kindle.env: $HOST"
    else
        echo "usage: $0 <ssh-host> [--port N] [--log] [--kill]" >&2
        exit 1
    fi
fi

# A plain TCP connect, so a port nobody is serving costs three seconds rather
# than an SSH timeout, and one that wants a password cannot stop at a prompt.
port_open() {
    local host="${1#*@}"
    timeout 3 bash -c "exec 3<>/dev/tcp/${host}/$2" 2>/dev/null
}

ports=()
if [ -n "$PORT" ]; then
    ports=("$PORT")
elif [ -n "${KINDLE_PORTS:-}" ]; then
    # shellcheck disable=SC2206
    ports=($KINDLE_PORTS)
else
    ports=(2222 22)
fi

PORT_FOUND=""
for candidate in "${ports[@]}"; do
    echo "==> checking $HOST:$candidate"
    if port_open "$HOST" "$candidate"; then
        PORT_FOUND="$candidate"
        break
    fi
    echo "    nothing listening"
done

if [ -z "$PORT_FOUND" ]; then
    cat >&2 <<EOF
error: cannot reach $HOST on ${ports[*]}.

Note that a frozen KOReader does not by itself stop SSH: the server is dropbear,
started as a separate process, so it keeps listening while KOReader's own loop
is stuck. If nothing answers, the reason is more likely one of these:

  * SSH was never started on this device (Menu -> Tools -> SSH), and a frozen
    KOReader cannot be asked to start it now.
  * Wi-Fi dropped -- which it does when the device sleeps.
  * The address is wrong, or the Kindle is on another network.

Turning SSH on and leaving it on is what makes this script available when it is
actually needed. Otherwise the device does have to be restarted by hand.
EOF
    exit 1
fi

SSH=(ssh -p "$PORT_FOUND" -o ConnectTimeout=10)

if [ "$FETCH_LOG" -eq 1 ]; then
    echo "==> fetching the plugin error log"
    if "${SSH[@]}" "$HOST" "test -f /mnt/us/koreader/scribe/scribe-error.log"; then
        "${SSH[@]}" "$HOST" "cat /mnt/us/koreader/scribe/scribe-error.log"
    else
        echo "    none -- the plugin has not reported a fault"
    fi
fi

echo "==> stopping KOReader"
"${SSH[@]}" "$HOST" "killall -TERM reader.lua 2>/dev/null || true"
sleep 3
# A process wedged in a Lua loop ignores nothing -- TERM is delivered to the
# process, and KOReader's handler runs between VM instructions -- but a process
# blocked in the kernel may not go. Insist.
"${SSH[@]}" "$HOST" "pgrep -f reader.lua >/dev/null && killall -KILL reader.lua 2>/dev/null || true"

if [ "$KILL_ONLY" -eq 1 ]; then
    echo "    stopped -- start it from the device when you want it back"
    exit 0
fi

echo "==> starting KOReader"
# Terminating reader.lua on a Kindle does not bring it back: there is no
# supervising loop the way there is under the emulator, so it has to be
# relaunched explicitly.
"${SSH[@]}" "$HOST" "cd /mnt/us/koreader && (setsid ./koreader.sh >/dev/null 2>&1 &)"

for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 3
    if "${SSH[@]}" "$HOST" "pgrep -f reader.lua >/dev/null" 2>/dev/null; then
        echo "    KOReader is back up"
        exit 0
    fi
done

echo "    WARNING: KOReader did not come back -- start it from the device" >&2
exit 1
