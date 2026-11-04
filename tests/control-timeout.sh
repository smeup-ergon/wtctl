#!/bin/sh
# In the Linux fixture: a stalled request must not leave dd holding its socket.
set -eu
export WTCTL_CONFIG_DIR=/test/timeout-config WTCTL_STATE_DIR=/test/timeout-state
mkdir -p /test
/work/wtctl status >/dev/null
/work/wtctl _receiver 28999 >/test/timeout-receiver.log 2>&1 & listener=$!
cleanup() { kill "$listener" 2>/dev/null || :; wait "$listener" 2>/dev/null || :; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
sleep 1
python3 - <<'PY'
import socket
import time

start = time.monotonic()
with socket.create_connection(('127.0.0.1', 28999), timeout=3) as client:
    client.settimeout(20)
    client.sendall(b'PUT 5\nabc')
    response = b''
    while chunk := client.recv(1024):
        response += chunk
    assert response == b'KO invalid-request\n', response
assert time.monotonic() - start < 20, 'server did not close at its read deadline'
print('Stalled control request closes at server deadline')
PY
# shellcheck disable=SC2009
# BusyBox baseline does not require the optional pgrep applet.
if ps -ef | grep '[d]d bs=1' >/dev/null; then
    printf 'Orphan control payload reader\n' >&2; exit 1
fi
