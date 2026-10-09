#!/bin/sh
# Regression: shutdown must be idempotent while an init system already sent TERM.
set -eu
export WTCTL_CONFIG_DIR=/test/race-config WTCTL_STATE_DIR=/test/race-state
export WTCTL_FIXTURE_CAPTURES=/test/race-captures WTCTL_FIXTURE_STOP_DELAY=3
unset WTCTL_FIXTURE_FAILURE
W=/work/wtctl
mkdir -p "$WTCTL_FIXTURE_CAPTURES"
trap '"$W" shutdown >/dev/null 2>&1 || :' EXIT
"$W" init
"$W" server add race --endpoint wss://example.com
"$W" tunnel add race --server race --listen 19999 --target localhost --port 80
"$W" enable race
"$W" binary use /fixture
"$W" apply
"$W" daemon --background
attempt=0
while ! grep -q '^state=running$' "$WTCTL_STATE_DIR/tunnels/race/status" 2>/dev/null; do
    attempt=$((attempt+1)); [ "$attempt" -lt 20 ]; sleep 1
done
manager=$(awk -F= '$1=="pid" {print $2}' "$WTCTL_STATE_DIR/daemon")
kill -TERM "$manager"
"$W" shutdown
[ ! -f "$WTCTL_STATE_DIR/daemon" ]
[ -z "$(ls -A "$WTCTL_STATE_DIR/requests")" ]
# No stale shutdown request may kill the next supervisor.
"$W" daemon --background
sleep 5
"$W" status | grep -q '^Supervisor: running$'
"$W" shutdown
printf 'Init TERM / concurrent shutdown regression passed.\n'
