#!/bin/sh
# Regression: shutdown must be idempotent while an init system already sent TERM.
set -eu
export WTCTL_CONFIG_DIR=/test/race-config WTCTL_STATE_DIR=/test/race-state
export WTCTL_FIXTURE_CAPTURES=/test/race-captures WTCTL_FIXTURE_STOP_DELAY=3
unset WTCTL_FIXTURE_FAILURE
W=/work/wtctl
mkdir -p "$WTCTL_FIXTURE_CAPTURES"
trap '"$W" shutdown >/dev/null 2>&1 || :' EXIT
"$W" status
mkdir -p "$WTCTL_STATE_DIR/bin"
cp /fixture "$WTCTL_STATE_DIR/bin/wstunnel"
"$W" _bootstrap https://example.com/manager
# Accept the provisioned fixture so activation needs no download.
printf 'manager_url=https://example.com/manager\nwstunnel_url=https://example.com/binary\n' > "$WTCTL_CONFIG_DIR/activation-state"
cat > /test/race.ini <<'EOF'
[wtctl]
format=1
url=https://example.com/manager
wstunnel_url=https://example.com/binary
[control]
enabled=false
server=race
[server race]
endpoint=wss://example.com
[tunnel race]
server=race
listen=19999
target=localhost
port=80
EOF
"$W" apply /test/race.ini | grep -qx 'OK 0'
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
