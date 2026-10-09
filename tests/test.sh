#!/bin/sh
# Disposable Linux/BusyBox fixture suite; no physical-hardware claims.
# shellcheck disable=SC2015,SC2016
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
wait_phase() {
    attempt=0
    while ! grep -q "$1" "$WTCTL_STATE_DIR/binary-status" 2>/dev/null; do
        attempt=$((attempt+1)); [ "$attempt" -lt 25 ] || fail "missing binary phase: $1"; sleep 1
    done
}
cleanup() { "$W" shutdown >/dev/null 2>&1 || :; [ -z "${server_pid:-}" ] || kill "$server_pid" 2>/dev/null || :; }
trap cleanup EXIT
trap 'exit 130' INT TERM

"$W" status
"$W" doctor
[ "$(stat -c %a /test/config)" = 700 ] && [ "$(stat -c %a /test/state)" = 700 ] || fail permissions
for command in init apply enable disable start stop binary; do expect_fail "$W" "$command"; done
ok 'automatic private initialization; removed commands rejected'
expect_fail "$W" server add ../escape --endpoint wss://example.com
expect_fail "$W" server add all --endpoint wss://example.com
expect_fail "$W" server add insecure --endpoint ws://example.com
expect_fail "$W" _setup ram http://example.com/binary
expect_fail "$W" tunnel add invalid --server absent --listen 0 --target localhost --port 80
expect_fail "$W" startup install openwrt
ok 'invalid settings and unapproved startup mutations rejected'

# Verified HTTPS setup and updates; downloaded client is test-only native ELF.
cp /fixture /test/fixture
openssl req -x509 -newkey rsa:2048 -nodes -keyout /test/key.pem -out /test/cert.pem -days 1 -subj /CN=localhost -addext subjectAltName=DNS:localhost >/dev/null 2>&1
export CURL_CA_BUNDLE=/test/cert.pem
python3 /work/tests/https-server.py /test & server_pid=$!
sleep 1
"$W" _setup ram https://localhost:18888/binary
[ -x /test/state/bin/wstunnel ] || fail 'setup did not download without tunnels'
ok 'setup downloads/validates binary and starts supervisor even with no tunnels'
printf '%s' 'secret $(touch /test/pwned); = $HOME' > /test/password
printf 'first\nsecond\n' > /test/multiline
expect_fail "$W" server add invalid --endpoint wss://example.com --auth basic --username user --password-file /test/multiline
"$W" server add main --endpoint wss://example.com --auth basic --username user --password-file /test/password
"$W" server add path --endpoint wss://example.net --auth path --prefix abc
"$W" server edit path --ca /test/password
"$W" server list > /test/list
! grep -q secret /test/list || fail 'credentials leaked'
[ ! -e /test/pwned ] || fail 'configuration executed'
expect_fail "$W" server add main --endpoint wss://example.com
expect_fail "$W" server edit missing --endpoint wss://example.com
ok 'data-only configuration, redacted listing and add/edit semantics'
for spec in ft:forward:tcp:19001:main fu:forward:udp:19002:path rt:reverse:tcp:19003:main ru:reverse:udp:19004:path; do
    IFS=: read -r name direction protocol listen server <<EOF
$spec
EOF
    "$W" tunnel add "$name" --server "$server" --direction "$direction" --protocol "$protocol" --listen "$listen" --target 127.0.0.1 --port 80
    wait_running "$name"
    ! grep -q '^enabled=' "/test/config/tunnels/$name" || fail 'persistent enabled state remains'
done
ok 'all four tunnel modes start immediately without apply or enable'
"$W" shutdown
mv /usr/bin/curl /usr/bin/curl.hidden
od_path=$(command -v od); mv "$od_path" "$od_path.hidden"
"$W" doctor > /test/no-curl
"$W" daemon --background
wait_running ft
mv "$od_path.hidden" "$od_path"; mv /usr/bin/curl.hidden /usr/bin/curl
grep -q 'Local binaries still work' /test/no-curl || fail 'optional curl not reported'
ok 'existing managed ELF works without curl; hexdump fallback supported'
expect_fail "$W" server remove main
before=$(head -n 1 /test/config/current)
expect_fail "$W" tunnel add conflict --server main --listen 19001 --target localhost --port 80
[ ! -e /test/config/tunnels/conflict ] && [ "$(head -n 1 /test/config/current)" = "$before" ] || fail 'conflict was not rolled back'
ok 'referential integrity and full-config listener conflicts roll back atomically'
ft_pid=$(pid ft); fu_pid=$(pid fu); rt_pid=$(pid rt)
grep -q '^-L$' "/test/captures/$ft_pid" && grep -q '^tcp://127.0.0.1:19001:127.0.0.1:80$' "/test/captures/$ft_pid" || fail 'forward TCP argv'
grep -q '^udp://127.0.0.1:19002:127.0.0.1:80$' "/test/captures/$fu_pid" || fail 'forward UDP argv'
grep -q '^-R$' "/test/captures/$rt_pid" || fail 'reverse argv'
grep -q '^--tls-verify-certificate$' "/test/captures/$ft_pid" && grep -Fq 'user:secret $(touch /test/pwned); = $HOME' "/test/captures/$ft_pid" || fail 'auth argv'
grep -q '^CA=/test/password$' "/test/captures/$fu_pid" || fail 'custom CA'
"$W" status > /test/status
! grep -q secret /test/status || fail 'status leaks secrets'
! find /test/state -name '*.log' | grep -q . || fail 'unexpected logs'
ok 'safe tunnel argv, credentials, custom CA and log-free status'
"$W" tunnel edit ft --port 81
wait_running ft
[ "$(pid ft)" != "$ft_pid" ] && [ "$(pid fu)" = "$fu_pid" ] && [ "$(pid rt)" = "$rt_pid" ] || fail 'implicit affected-only edit'
ok 'implicit edit restarts only affected tunnel before acknowledgment'
ft_pid=$(pid ft); rt_pid=$(pid rt)
"$W" server edit main --endpoint wss://changed.example.com
wait_running ft; wait_running rt
[ "$(pid ft)" != "$ft_pid" ] && [ "$(pid rt)" != "$rt_pid" ] && [ "$(pid fu)" = "$fu_pid" ] || fail 'shared server restart scope'
ok 'shared profile edit immediately restarts exactly its tunnels'
for iteration in 1 2 3 4 5; do printf 'Snapshot stress %s\n' "$iteration"; "$W" server edit path --prefix abc; done
sleep 6
snapshot=$(head -n 1 /test/config/current)
[ -f "$snapshot/ft/tunnel" ] || fail 'published snapshot collected'
ok 'automatic snapshots safe against collection'
: > /test/failure
sleep 3
rm /test/failure
wait_running ft
[ "$(field /test/state/tunnels/ft/status restarts)" -ge 1 ] || fail 'no restart count'
[ "$(field /test/state/tunnels/ft/status exit)" = 7 ] || fail 'last exit missing'
ok 'unreachable/failing client stays configured and retries'
removed_pid=$(pid ru)
"$W" tunnel remove ru
[ ! -d /test/state/tunnels/ru ] && [ ! -e /test/config/tunnels/ru ] || fail 'remove not reconciled'
! kill -0 "$removed_pid" 2>/dev/null || fail 'removed child still running'
ok 'remove is persistent stop, no disabled records retained'
# A stale process token must never signal an unrelated process.
sleep 120 & unrelated=$!
mkdir -p /test/state/tunnels/stale
printf 'pid=%s\ntoken=not-the-process-start-time\n' "$unrelated" > /test/state/tunnels/stale/child
"$W" shutdown
kill -0 "$unrelated" || fail 'unrelated process killed'
kill "$unrelated"; wait "$unrelated" 2>/dev/null || :
"$W" daemon --background
wait_running ft
old_child=$(pid ft)
manager=$(field /test/state/daemon pid)
kill -KILL "$manager"
sleep 2
"$W" daemon --background
wait_running ft
[ "$(pid ft)" != "$old_child" ] || fail 'orphaned child not replaced'
! kill -0 "$old_child" 2>/dev/null || fail 'orphaned child survived'
ok 'PID reuse protection and crashed supervisor orphan recovery'
"$W" tunnel edit ft --port 83
"$W" shutdown
rm -rf /test/state
"$W" daemon --background
wait_phase '^ready'; wait_running ft
reboot_pid=$(pid ft)
grep -q '^tcp://127.0.0.1:19001:127.0.0.1:83$' "/test/captures/$reboot_pid" || fail 'latest edit lost after reboot'
ok 'boot restores every saved tunnel and redownloads lost RAM binary'
# Update failures must preserve binary, settings AND live tunnel processes.
cp /test/config/global /test/global.saved
cp /test/state/bin/wstunnel /test/binary.saved
ft_pid=$(pid ft)
for endpoint in failure bad redirect-http; do
    expect_fail "$W" _setup ram "https://localhost:18888/$endpoint"
    cmp /test/global.saved /test/config/global || fail 'failed update changed settings'
    cmp /test/binary.saved /test/state/bin/wstunnel || fail 'failed update removed old binary'
    [ "$(pid ft)" = "$ft_pid" ] || fail 'failed download disrupted tunnel'
done
ok 'failed/invalid/downgraded updates preserve working state'
"$W" _setup '' ''
[ "$(pid ft)" = "$ft_pid" ] || fail 'idempotent setup restarted clients'
"$W" _setup ram https://localhost:18888/binary
wait_running ft
[ "$(pid ft)" != "$ft_pid" ] || fail 'supplied URL did not update existing binary'
ok 'setup rerun preserves configuration; supplied URL really updates'
"$W" _setup persistent https://localhost:18888/binary
[ -x /test/config/bin/wstunnel ] || fail 'persistent binary missing'
"$W" shutdown
rm -rf /test/state
"$W" daemon --background
wait_running ft
ok 'persistent storage survives runtime loss'
# Boot download retries must actually recover after WAN restoration.
: > /test/wan-up
"$W" _setup ram https://localhost:18888/flaky
"$W" shutdown
rm /test/wan-up /test/state/bin/wstunnel
"$W" daemon --background
wait_phase '^download-failed$'
retry_wait=0
while [ "$(head -n 1 /test/state/next-download)" -le "$(date +%s)" ]; do
    sleep 1; retry_wait=$((retry_wait+1)); [ "$retry_wait" -lt 10 ] || fail 'retry not scheduled'
done
next=$(head -n 1 /test/state/next-download); now=$(date +%s)
[ "$((next-now))" -le 36 ] || fail 'initial retry outside sustainable bounds'
: > /test/wan-up
recovery_wait=0
while [ ! -x /test/state/bin/wstunnel ]; do
    sleep 1; recovery_wait=$((recovery_wait+1)); [ "$recovery_wait" -lt 60 ] || fail 'WAN restoration did not recover'
done
wait_running ft
"$W" _setup persistent https://localhost:18888/binary
ok 'boot download schedules bounded retries and actually recovers on WAN restoration'
# Local validation failure restores the previous saved record/pointer.
cp /test/config/bin/wstunnel /test/binary.saved
"$W" shutdown
printf 'not executable\n' > /test/config/bin/wstunnel
before=$(head -n 1 /test/config/current)
expect_fail "$W" tunnel edit ft --port 84
[ "$(field /test/config/tunnels/ft port)" = 83 ] && [ "$(head -n 1 /test/config/current)" = "$before" ] || fail 'local failure not rolled back'
cp /test/binary.saved /test/config/bin/wstunnel
"$W" shutdown; "$W" daemon --background; wait_running ft
ok 'local binary failure rolls back saved edit and active generation'
before=$(head -n 1 /test/config/current)
printf 'blocked runtime directory\n' > /test/state/tunnels/localfail
expect_fail "$W" tunnel add localfail --server main --listen 19009 --target localhost --port 80
[ ! -e /test/config/tunnels/localfail ] && [ "$(head -n 1 /test/config/current)" = "$before" ] || fail 'worker launch failure not rolled back'
rm /test/state/tunnels/localfail
wait_running ft
"$W" status | grep -q '^Supervisor: running$' || fail 'rollback did not recover supervisor'
ok 'local worker launch failure restores configuration and crashed supervisor'
cp /test/config/global /test/global.saved
awk '/^format=/ {$0="format=999"} {print}' /test/global.saved > /test/config/global
expect_fail "$W" server add unknown --endpoint wss://example.com
[ ! -e /test/config/servers/unknown ] || fail 'invalid schema accepted'
mv /test/global.saved /test/config/global
printf 'endpoint=wss://example.com\nauth=none\nprefix=v1\nusername=\npassword=\nca=\nunknown=$(touch /test/pwned)\n' > /test/config/servers/evil
expect_fail "$W" server edit main --prefix v2
[ ! -e /test/pwned ] || fail 'configuration executed'
rm /test/config/servers/evil
mkdir -p /test/foreign
ln -s /test/foreign /test/linked
expect_fail env WTCTL_STATE_DIR=/test/linked "$W" status
expect_fail env WTCTL_STATE_DIR=/test/config "$W" status
ok 'unknown schema, injection, symlink and path overlap fail closed'
"$W" uninstall --yes
[ -f /test/config/global ] && [ -x /test/config/bin/wstunnel ] && [ ! -e /test/state ] || fail 'uninstall preservation'
"$W" uninstall --purge --yes
[ ! -e /test/config ] || fail 'purge'
ok 'uninstall and explicit purge'
sh /work/tests/shutdown-race.sh
ok 'shutdown racing init-system TERM'
python3 /work/tests/menu.py
ok 'single-key menus, choices, password hiding and terminal restoration'
sh /work/tests/startup.sh
ok 'startup adapters, ownership safeguards and unified installer'
printf '\n%s fixture groups passed; physical qualification still required.\n' "$checks"
