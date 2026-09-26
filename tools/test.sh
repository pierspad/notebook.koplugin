#!/usr/bin/env bash
# Each suite has its own Lua VM; logs are isolated even across simultaneous runs.
set -euo pipefail
cd "$(dirname "$0")/../lua"
jobs=${TEST_JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN)}
if [[ ! $jobs =~ ^[1-9][0-9]*$ ]]; then
    echo 'TEST_JOBS must be a positive integer' >&2
    exit 2
fi
(( jobs > $# )) && jobs=$#
logs=$(mktemp -d "${TMPDIR:-/tmp}/notebook-tests.XXXXXXXX")
trap 'rm -rf "$logs"' EXIT
export NOTEBOOK_TEST_LOGS="$logs"
printf 'Running %s suites with %s workers\n' "$#" "$jobs"
status=0
printf '%s\n' "$@" | xargs -P "$jobs" -n 1 bash -c '
    luajit "spec/$1.lua" > "$NOTEBOOK_TEST_LOGS/$1.log" 2>&1 || {
        touch "$NOTEBOOK_TEST_LOGS/$1.failed"
        exit 1
    }
' _ || status=1
for suite in "$@"; do
    printf '%-16s ' "$suite"
    if [[ -f "$logs/$suite.failed" ]]; then
        echo FAILED
        cat "$logs/$suite.log"
    else
        tail -1 "$logs/$suite.log"
    fi
done
exit "$status"
