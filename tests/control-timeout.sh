#!/bin/sh
# In the Linux fixture: a stalled request must not leave dd holding its session.
set -eu
export WTCTL_CONFIG_DIR=/test/timeout-config WTCTL_STATE_DIR=/test/timeout-state
mkdir -p /test
/work/wtctl status >/dev/null
# The receiver account is normally managed by activation; this probe adds it.
grep -q '^wtctl:' /etc/passwd || printf 'wtctl::0:0:wtctl control receiver:/:/bin/sh\n' >> /etc/passwd
/work/wtctl _receiver 28999 >/test/timeout-receiver.log 2>&1 & listener=$!
cleanup() { kill "$listener" 2>/dev/null || :; wait "$listener" 2>/dev/null || :; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
sleep 2
# Send an incomplete PUT, keep stdin open well past the 15 s read deadline,
# and require the session to end (client exit) long before stdin closes.
{ printf 'PUT 5\nabc'; sleep 40; } | dbclient -y -y -T -p 28999 wtctl@127.0.0.1 x > /test/timeout-reply 2>/dev/null &
client=$!
elapsed=0
while kill -0 "$client" 2>/dev/null; do
    sleep 1; elapsed=$((elapsed+1))
    [ "$elapsed" -lt 25 ] || { printf 'Receiver did not close at its read deadline\n' >&2; exit 1; }
done
reply=$(cat /test/timeout-reply)
[ "$reply" = 'KO invalid-request' ] || { printf 'Unexpected reply: %s\n' "$reply" >&2; exit 1; }
printf 'Stalled control request closes at server deadline\n'
# shellcheck disable=SC2009
# BusyBox baseline does not require the optional pgrep applet.
if ps -ef | grep '[d]d bs=1' >/dev/null; then
    printf 'Orphan control payload reader\n' >&2; exit 1
fi
