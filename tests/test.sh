#!/bin/sh
# shellcheck disable=SC2015,SC2016
# Literal shell syntax in credentials is deliberately an injection regression test.
set -eu
export WTCTL_CONFIG_DIR=/test/config WTCTL_STATE_DIR=/test/state
export WTCTL_FIXTURE_CAPTURES=/test/captures WTCTL_FIXTURE_FAILURE=/test/failure
W=/work/wtctl
mkdir -p /test/captures
checks=0
ok() { checks=$((checks+1)); printf 'ok %s - %s\n' "$checks" "$1"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; "$W" status || :; exit 1; }
expect_fail() { if "$@" >/test/command.out 2>&1; then fail "unexpected success: $*"; fi; }
field() { awk -F= -v k="$2" '$1==k {print substr($0,length(k)+2);exit}' "$1" 2>/dev/null; }
pid() { field "$WTCTL_STATE_DIR/tunnels/$1/status" pid || :; }
wait_running() {
    attempt=0
    while :; do
        p=$(pid "$1"); [ -z "$p" ] || { kill -0 "$p" 2>/dev/null && [ -f "/test/captures/$p" ] && return 0; }
        attempt=$((attempt+1)); [ "$attempt" -lt 25 ] || fail "not running: $1"; sleep 1
    done
}
wait_stopped() {
    attempt=0
    while [ -n "$(pid "$1")" ]; do
        attempt=$((attempt+1)); [ "$attempt" -lt 25 ] || fail "not stopped: $1"; sleep 1
    done
}
wait_phase() {
    attempt=0
    while ! grep -q "$1" "$WTCTL_STATE_DIR/binary-status" 2>/dev/null; do
        attempt=$((attempt+1)); [ "$attempt" -lt 25 ] || fail "missing binary phase: $1"; sleep 1
    done
}
cleanup() { "$W" shutdown >/dev/null 2>&1 || :; [ -z "${server_pid:-}" ] || kill "$server_pid" 2>/dev/null || :; }
trap cleanup EXIT
trap 'exit 130' INT TERM

"$W" init
"$W" doctor
ok 'initialization and BusyBox capability checks'
[ "$(stat -c %a /test/config)" = 700 ] && [ "$(stat -c %a /test/state)" = 700 ] || fail permissions
ok 'private directories'
expect_fail "$W" server add ../escape --endpoint wss://example.com
expect_fail "$W" server add all --endpoint wss://example.com
expect_fail "$W" server add global --endpoint wss://example.com
expect_fail "$W" server add insecure --endpoint ws://example.com
expect_fail "$W" binary configure ram http://example.com/binary
expect_fail "$W" tunnel add invalid --server absent --listen 0 --target localhost --port 80
expect_fail "$W" startup install openwrt
expect_fail "$W" binary update
ok 'invalid identifiers, settings and unapproved mutations rejected'

printf '%s' 'secret $(touch /test/pwned); = $HOME' > /test/password
printf 'first\nsecond\n' > /test/multiline
expect_fail "$W" server add invalid --endpoint wss://example.com --auth basic --username user --password-file /test/multiline
"$W" server add main --endpoint wss://example.com --auth basic --username user --password-file /test/password
"$W" server add path --endpoint wss://example.net --auth path --prefix abc
"$W" server edit path --ca /test/password
"$W" server list > /test/list
! grep -q secret /test/list || fail 'credentials leaked in list'
[ ! -e /test/pwned ] || fail 'configuration executed'
ok 'data-only configuration and redacted listing'
expect_fail "$W" server add main --endpoint wss://example.com
expect_fail "$W" server edit missing --endpoint wss://example.com
ok 'record add/edit semantics'

for spec in ft:forward:tcp:19001:main fu:forward:udp:19002:path rt:reverse:tcp:19003:main ru:reverse:udp:19004:path; do
    IFS=: read -r name direction protocol listen server <<EOF
$spec
EOF
    "$W" tunnel add "$name" --server "$server" --direction "$direction" --protocol "$protocol" --listen "$listen" --target 127.0.0.1 --port 80
    "$W" enable "$name"
done
"$W" tunnel add disabled --server main --listen 19005 --target localhost --port 80
"$W" disable all
[ "$(field /test/config/tunnels/ft enabled)" = 0 ] || fail 'disable all failed'
"$W" enable all
"$W" disable disabled
[ "$(field /test/config/tunnels/ft enabled)" = 1 ] && [ "$(field /test/config/tunnels/disabled enabled)" = 0 ] || fail 'enable all failed'
ok 'persistent enable/disable all preferences'
expect_fail "$W" server remove main
"$W" tunnel add conflict --server main --listen 19001 --target localhost --port 80
"$W" enable conflict
expect_fail "$W" apply
"$W" tunnel remove conflict
ok 'referential integrity and listener conflict detection'

mv /usr/bin/curl /usr/bin/curl.hidden
"$W" doctor > /test/no-curl
od_path=$(command -v od)
mv "$od_path" "$od_path.hidden"
"$W" binary use /fixture
mv "$od_path.hidden" "$od_path"
ok 'hexdump fallback validates ELF on OpenWrt-style applet baselines'
"$W" apply
"$W" daemon --background
for name in ft fu rt ru; do wait_running "$name"; done
[ -z "$(pid disabled)" ] || fail 'disabled tunnel started at boot'
ok 'supervisor restores only enabled tunnels'
grep -q 'Local binaries still work' /test/no-curl || fail 'optional curl capability not reported'
mv /usr/bin/curl.hidden /usr/bin/curl
ok 'local executable lifecycle works without curl'
ft_pid=$(pid ft); fu_pid=$(pid fu); rt_pid=$(pid rt); ru_pid=$(pid ru)
grep -q '^-L$' "/test/captures/$ft_pid" && grep -q '^tcp://127.0.0.1:19001:127.0.0.1:80$' "/test/captures/$ft_pid" || fail 'forward TCP argv'
grep -q '^udp://127.0.0.1:19002:127.0.0.1:80$' "/test/captures/$fu_pid" || fail 'forward UDP argv'
grep -q '^-R$' "/test/captures/$rt_pid" && grep -q '^tcp://127.0.0.1:19003:127.0.0.1:80$' "/test/captures/$rt_pid" || fail 'reverse TCP argv'
grep -q '^udp://127.0.0.1:19004:127.0.0.1:80$' "/test/captures/$ru_pid" || fail 'reverse UDP argv'
grep -q '^--tls-verify-certificate$' "/test/captures/$ft_pid" && grep -Fq 'user:secret $(touch /test/pwned); = $HOME' "/test/captures/$ft_pid" || fail 'auth argv'
grep -q '^CA=/test/password$' "/test/captures/$fu_pid" && grep -q '^--http-upgrade-path-prefix$' "/test/captures/$fu_pid" || fail 'path auth/custom CA'
[ ! -e /test/pwned ] || fail 'secret executed'
ok 'forward/reverse TCP/UDP, auth and custom CA argv'
"$W" status > /test/status
! grep -q secret /test/status || fail 'status leaks secrets'
! find /test/state -name '*.log' | grep -q . || fail 'unexpected logs'
ok 'status without credential leaks or tunnel logs'

"$W" tunnel edit ft --port 81
sleep 2
[ "$(pid ft)" = "$ft_pid" ] || fail 'unapplied edit restarted tunnel'
"$W" apply
attempt=0
while [ "$(pid ft)" = "$ft_pid" ] || [ -z "$(pid ft)" ]; do attempt=$((attempt+1)); [ "$attempt" -lt 20 ] || fail 'apply not reconciled'; sleep 1; done
wait_running ft
[ "$(pid fu)" = "$fu_pid" ] && [ "$(pid rt)" = "$rt_pid" ] || fail 'unaffected tunnel restarted'
ok 'explicit apply restarts only affected tunnels'
for iteration in 1 2 3 4 5; do printf 'Snapshot stress apply %s\n' "$iteration"; "$W" apply; done
sleep 6
snapshot=$(head -n 1 /test/config/current)
[ -f "$snapshot/ft/tunnel" ] || fail 'published snapshot was collected'
wait_running ft
ok 'successive applies remain safe against snapshot collection'

"$W" stop ft
sleep 2
[ -z "$(pid ft)" ] || fail 'manual stop ignored'
"$W" apply
sleep 2
[ -z "$(pid ft)" ] || fail 'manual stop lost on apply'
"$W" start ft
wait_running ft
ok 'temporary stop survives apply; explicit start restores tunnel'
"$W" disable ft
sleep 2
[ -n "$(pid ft)" ] || fail 'disable applied prematurely'
"$W" apply
wait_stopped ft
[ -z "$(pid ft)" ] || fail 'disable did not stop tunnel'
"$W" enable ft
"$W" apply
wait_running ft
ok 'enable/disable changes take effect on apply'

: > /test/failure
sleep 3
rm /test/failure
wait_running ft
[ "$(field /test/state/tunnels/ft/status restarts)" -ge 1 ] || fail 'no restart count'
[ "$(field /test/state/tunnels/ft/status exit)" = 7 ] || fail 'last exit missing'
ok 'per-tunnel failure recovery and lightweight status'

# A stale ownership token must never signal an unrelated process.
sleep 120 & unrelated=$!
mkdir -p /test/state/tunnels/stale
printf 'pid=%s\ntoken=not-the-process-start-time\n' "$unrelated" > /test/state/tunnels/stale/child
"$W" stop all
kill -0 "$unrelated" || fail 'unrelated process killed'
kill "$unrelated"; wait "$unrelated" 2>/dev/null || :
ok 'PID reuse protection and no blanket process killing'
"$W" shutdown
"$W" daemon --background
wait_running ft
ok 'supervisor restart clears temporary stops'
old_child=$(pid ft)
manager=$(field /test/state/daemon pid)
kill -KILL "$manager"
sleep 2
"$W" daemon --background
wait_running ft
[ "$(pid ft)" != "$old_child" ] || fail 'orphaned child not replaced'
! kill -0 "$old_child" 2>/dev/null || fail 'orphaned child survived recovery'
ok 'crashed-supervisor recovery cleans owned orphans'
"$W" shutdown
[ -x /fixture ] || fail 'external executable deleted'
ok 'shutdown preserves external binaries'
"$W" tunnel edit ft --port 83
rm -rf /test/state
"$W" daemon --background
wait_running ft
reboot_pid=$(pid ft)
grep -q '^tcp://127.0.0.1:19001:127.0.0.1:81$' "/test/captures/$reboot_pid" || fail 'unapplied draft became active after runtime loss'
"$W" shutdown
"$W" tunnel edit ft --port 81
"$W" apply
ok 'last applied configuration survives runtime loss without activating pending drafts'

# Real curl against locally trusted HTTPS; downloaded executable remains a fixture.
cp /fixture /test/fixture
openssl req -x509 -newkey rsa:2048 -nodes -keyout /test/key.pem -out /test/cert.pem -days 1 -subj /CN=localhost -addext subjectAltName=DNS:localhost >/dev/null 2>&1
export CURL_CA_BUNDLE=/test/cert.pem
python3 /work/tests/https-server.py /test & server_pid=$!
sleep 1
"$W" binary configure ram https://localhost:18888/binary
"$W" apply
"$W" daemon --background
wait_phase '^ready'
wait_running ft
[ -x /test/state/bin/wstunnel ] || fail 'RAM executable missing'
ok 'verified HTTPS download and RAM activation'
"$W" shutdown
rm /test/state/bin/wstunnel
"$W" daemon --background
wait_phase '^ready'
wait_running ft
ok 'RAM executable recovery after simulated reboot loss'

"$W" binary configure ram https://localhost:18888/failure
"$W" apply
"$W" binary update --yes
wait_phase '^download-failed$'
[ ! -e /test/state/bin/wstunnel ] || fail 'old executable retained during destructive update'
[ -z "$(pid ft)" ] || fail 'tunnel running during failed update'
next=$(head -n 1 /test/state/next-download)
now=$(date +%s)
attempt=0
while [ "$next" -le "$now" ]; do sleep 1; attempt=$((attempt+1)); [ "$attempt" -lt 10 ] || fail 'download retry not scheduled'; next=$(head -n 1 /test/state/next-download); done
now=$(date +%s)
[ "$((next-now))" -le 36 ] || fail 'initial retry interval outside bounds'
ok 'destructive update failure leaves tunnels down and schedules sustainable retry'
"$W" stop all
sleep 6
[ "$(head -n 1 /test/state/next-download)" = 0 ] || fail 'stop did not cancel retries'
ok 'explicit stop cancels download recovery'

"$W" binary configure ram https://localhost:18888/flaky
"$W" apply
"$W" binary install --yes
wait_phase '^download-failed$'
: > /test/wan-up
attempt=0
while [ ! -x /test/state/bin/wstunnel ]; do
    attempt=$((attempt+1)); [ "$attempt" -lt 60 ] || fail 'WAN recovery did not retry'; sleep 1
 done
wait_phase '^ready'
ok 'download retries actually recover after WAN restoration without operator intervention'
"$W" binary configure ram https://localhost:18888/redirect-http
"$W" apply
"$W" binary install --yes
wait_phase '^download-failed$'
ok 'HTTPS-to-HTTP redirect rejected'
"$W" binary configure ram https://localhost:18888/bad
"$W" apply
"$W" binary install --yes
wait_phase '^incompatible-binary$'
[ ! -e /test/state/bin/wstunnel ] || fail 'invalid ELF activated'
ok 'invalid downloaded executable rejected'
"$W" stop all
"$W" binary configure persistent https://localhost:18888/binary
"$W" apply
"$W" binary install --yes
wait_phase '^ready'
[ -x /test/config/bin/wstunnel ] || fail 'persistent executable missing'
[ -z "$(pid ft)" ] || fail 'install overrides manual stop'
ok 'explicit install works without wanted tunnels; persistent storage supported'
"$W" shutdown
"$W" daemon --background
wait_running ft
"$W" shutdown
ok 'persistent executable restores enabled tunnels'

# Unknown schema versions fail closed.
cp /test/config/global /test/global.saved
awk '/^format=/ {$0="format=2"} {print}' /test/global.saved > /test/config/global
expect_fail "$W" apply
mv /test/global.saved /test/config/global
ok 'unknown configuration schema version rejected'
# Apply and hand-edited data must never execute arbitrary shell text.
printf 'endpoint=wss://example.com\nauth=none\nprefix=v1\nusername=\npassword=\nca=\nunknown=$(touch /test/pwned)\n' > /test/config/servers/evil
expect_fail "$W" apply
[ ! -e /test/pwned ] || fail 'hand-edited configuration executed'
rm /test/config/servers/evil
mkdir -p /test/foreign
ln -s /test/foreign /test/linked
expect_fail env WTCTL_STATE_DIR=/test/linked "$W" init
expect_fail env WTCTL_STATE_DIR=/test/config "$W" init
ok 'strict schema, symlink and path-overlap protections'
"$W" uninstall --yes
[ -f /test/config/global ] && [ -x /test/config/bin/wstunnel ] && [ -x /fixture ] || fail 'configuration or external binary removed'
[ ! -e /test/state ] || fail 'runtime state remains after uninstall'
ok 'uninstall preserves configuration and external binaries'
"$W" uninstall --purge --yes
[ ! -e /test/config ] && [ -x /fixture ] || fail 'purge behavior'
ok 'explicit purge removes only manager configuration'
sh /work/tests/shutdown-race.sh
ok 'idempotent shutdown racing an init-system TERM'
python3 /work/tests/menu.py
ok 'interactive menu, hidden password entry and correct removal'
sh /work/tests/startup.sh
ok 'startup adapter generation, ownership safeguards and installation helper'
printf '\n%s checks passed. Fixture lifecycle tests do not qualify physical hardware or real tunnel traffic.\n' "$checks"
