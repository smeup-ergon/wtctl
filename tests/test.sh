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
# Complete desired configuration with control disabled. Overrides: BINARY,
# STORAGE, FT_PORT, MAIN_ENDPOINT, EXTRA (appended text), OMIT (tunnel name).
config() {
    printf '[wtctl]\nformat=1\nurl=https://localhost:18888/manager\n'
    printf 'wstunnel_url=https://localhost:18888/%s\nstorage=%s\n' "${BINARY:-binary}" "${STORAGE:-ram}"
    printf '[control]\nenabled=false\nserver=main\n'
    printf '[server main]\nendpoint=%s\nauth=basic\nusername=user\n' "${MAIN_ENDPOINT:-wss://example.com}"
    printf '%s\n' 'password=secret $(touch /test/pwned); = $HOME'
    printf '[server path]\nendpoint=wss://example.net\nauth=path\nprefix=abc\nca=/test/ca-file\n'
    for spec in "ft:forward:tcp:19001:main:${FT_PORT:-80}" fu:forward:udp:19002:path:80 rt:reverse:tcp:19003:main:80 ru:reverse:udp:19004:path:80; do
        IFS=: read -r name direction protocol listen server port <<EOF
$spec
EOF
        [ "$name" != "${OMIT:-}" ] || continue
        printf '[tunnel %s]\nserver=%s\ndirection=%s\nprotocol=%s\nlisten=%s\ntarget=127.0.0.1\nport=%s\n' \
            "$name" "$server" "$direction" "$protocol" "$listen" "$port"
    done
    printf '%s' "${EXTRA:-}"
}
apply() { config > /test/draft.ini; "$W" apply /test/draft.ini > /test/apply.out 2>&1; }
applied() { apply || fail "apply failed: $(cat /test/apply.out)"; grep -qx 'OK 0' /test/apply.out || fail 'apply did not report OK 0'; }
cleanup() { "$W" shutdown >/dev/null 2>&1 || :; [ -z "${server_pid:-}" ] || kill "$server_pid" 2>/dev/null || :; }
trap cleanup EXIT
trap 'exit 130' INT TERM

"$W" status
"$W" doctor
[ "$(stat -c %a /test/config)" = 700 ] && [ "$(stat -c %a /test/state)" = 700 ] || fail permissions
"$W" > /test/help.out
grep -q 'apply FILE' /test/help.out && ! grep -q menu /test/help.out || fail 'bare wtctl does not print help'
for command in menu server tunnel init enable disable start stop binary startup _setup _approve _adapter _handoff; do expect_fail "$W" "$command"; done
expect_fail "$W" server add main --endpoint wss://example.com
ok 'automatic private initialization; bare command prints help; menus and record commands removed'

# Verified HTTPS downloads; downloaded client is a test-only native ELF.
cp /fixture /test/fixture
cp "$W" /test/manager
printf 'test CA\n' > /test/ca-file
openssl req -x509 -newkey rsa:2048 -nodes -keyout /test/key.pem -out /test/cert.pem -days 1 -subj /CN=localhost -addext subjectAltName=DNS:localhost >/dev/null 2>&1
export CURL_CA_BUNDLE=/test/cert.pem
python3 /work/tests/https-server.py /test & server_pid=$!
sleep 1
"$W" _bootstrap https://localhost:18888/manager
"$W" daemon --background
"$W" status | grep -q '^Supervisor: running$' || fail 'bootstrap supervisor not idle-running'
[ ! -d "$(head -n 1 /test/config/current)/__control" ] || fail 'bootstrap enabled control'
ok 'bootstrap active state: idle supervisor, control disabled, no tunnels'

applied
[ -x /test/state/bin/wstunnel ] || fail 'apply did not download binary'
for name in ft fu rt ru; do wait_running "$name"; done
cmp /test/draft.ini /test/config/active.ini || fail 'active INI not recorded'
[ "$(field /test/config/activation-state manager_url)" = https://localhost:18888/manager ] || fail 'manager URL not accepted'
[ ! -e /test/pwned ] || fail 'configuration executed'
ok 'INI apply downloads the binary and starts all four tunnel modes'

"$W" shutdown
mv /usr/bin/curl /usr/bin/curl.hidden
od_path=$(command -v od); mv "$od_path" "$od_path.hidden"
"$W" doctor > /test/no-curl || :
"$W" daemon --background
for name in ft fu rt ru; do wait_running "$name"; done
mv "$od_path.hidden" "$od_path"; mv /usr/bin/curl.hidden /usr/bin/curl
grep -q 'Local binaries still work' /test/no-curl || fail 'optional curl not reported'
grep -q 'Control receiver: BusyBox nc' /test/no-curl || fail 'nc capability not reported'
! grep -q stty /test/no-curl || fail 'stty still checked'
ok 'existing managed ELF works without curl; hexdump fallback; doctor checks nc, not stty'

before=$(head -n 1 /test/config/current)
cp /test/config/desired.ini /test/desired.saved
EXTRA='[tunnel conflict]
server=main
listen=19001
target=localhost
port=80
' apply && fail 'listener conflict accepted'
grep -q 'KO invalid-configuration' /test/apply.out || fail 'conflict not reported as invalid'
EXTRA='[server unused]
endpoint=wss://example.org
unknown=$(touch /test/pwned)
' apply && fail 'unknown field accepted'
[ ! -e /test/pwned ] || fail 'configuration executed'
cmp /test/desired.saved /test/config/desired.ini || fail 'invalid draft replaced desired'
[ "$(head -n 1 /test/config/current)" = "$before" ] || fail 'invalid draft changed active state'
ok 'listener conflicts, unknown fields and injection rejected without changing desired or active state'

ft_pid=$(pid ft); fu_pid=$(pid fu); rt_pid=$(pid rt)
grep -q '^-L$' "/test/captures/$ft_pid" && grep -q '^tcp://127.0.0.1:19001:127.0.0.1:80$' "/test/captures/$ft_pid" || fail 'forward TCP argv'
grep -q '^udp://127.0.0.1:19002:127.0.0.1:80$' "/test/captures/$fu_pid" || fail 'forward UDP argv'
grep -q '^-R$' "/test/captures/$rt_pid" || fail 'reverse argv'
grep -q '^--tls-verify-certificate$' "/test/captures/$ft_pid" && grep -Fq 'user:secret $(touch /test/pwned); = $HOME' "/test/captures/$ft_pid" || fail 'auth argv'
grep -q '^CA=/test/ca-file$' "/test/captures/$fu_pid" || fail 'custom CA'
"$W" status > /test/status
! grep -q secret /test/status || fail 'status leaks secrets'
! find /test/state -name '*.log' | grep -q . || fail 'unexpected logs'
ok 'safe tunnel argv, credentials, custom CA and log-free status'

for spec in ft:forward:tcp:19001:main fu:forward:udp:19002:path rt:reverse:tcp:19003:main ru:reverse:udp:19004:path; do
    IFS=: read -r name direction protocol listen server <<EOF
$spec
EOF
    details="server=$server $direction/$protocol listen=127.0.0.1:$listen target=127.0.0.1:80"
    awk -v name="$name" '$1==name' /test/status | grep -Fq "$details" || fail 'status missing endpoints'
done
EXTRA='[tunnel ipv6]
server=main
bind=::1
listen=19005
target=[::1]
port=8080
' applied
wait_running ipv6
"$W" status > /test/status
awk '$1=="ipv6"' /test/status | grep -Fq 'server=main forward/tcp listen=[::1]:19005 target=[::1]:8080' || fail 'IPv6 status formatting'
grep -Fqx 'Process state only; connectivity is not verified.' /test/status || fail 'status disclaimer missing'
applied
[ ! -d /test/state/tunnels/ipv6 ] || fail 'omitted IPv6 tunnel not removed'
ok 'status endpoint details for all modes and IPv6; omission removes a tunnel'

ft_pid=$(pid ft); fu_pid=$(pid fu); rt_pid=$(pid rt)
FT_PORT=81 applied
wait_running ft
[ "$(pid ft)" != "$ft_pid" ] && [ "$(pid fu)" = "$fu_pid" ] && [ "$(pid rt)" = "$rt_pid" ] || fail 'affected-only edit'
ok 'tunnel edit restarts only the affected tunnel before acknowledgment'
ft_pid=$(pid ft); rt_pid=$(pid rt)
FT_PORT=81 MAIN_ENDPOINT=wss://changed.example.com applied
wait_running ft; wait_running rt
[ "$(pid ft)" != "$ft_pid" ] && [ "$(pid rt)" != "$rt_pid" ] && [ "$(pid fu)" = "$fu_pid" ] || fail 'shared server restart scope'
ok 'shared server edit restarts exactly its tunnels'
export FT_PORT=81 MAIN_ENDPOINT=wss://changed.example.com
for iteration in 1 2 3 4 5; do
    printf 'Snapshot stress %s\n' "$iteration"
    EXTRA="# revision $iteration
" applied
done
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
# All workers saw the injected failure. Wait for this worker too, and retain
# the PID validated by wait_running rather than resampling a transient status.
wait_running ru
removed_pid=$p
OMIT=ru applied
[ ! -d /test/state/tunnels/ru ] && [ ! -e /test/config/tunnels/ru ] || fail 'omission not reconciled'
if kill -0 "$removed_pid" 2>/dev/null; then
    removed_state=$(awk '{sub(/^.*\) /, ""); print $1}' "/proc/$removed_pid/stat" 2>/dev/null || :)
    fail "removed child still running (process state: $removed_state)"
fi
applied
wait_running ru
ok 'omitted tunnel stops persistently; resubmission restores it'

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

FT_PORT=83 applied
"$W" shutdown
rm -rf /test/state
"$W" daemon --background
wait_phase '^ready'; wait_running ft
reboot_pid=$(pid ft)
grep -q '^tcp://127.0.0.1:19001:127.0.0.1:83$' "/test/captures/$reboot_pid" || fail 'latest edit lost after reboot'
ok 'boot restores accepted tunnels and redownloads lost RAM binary from the accepted URL'
export FT_PORT=83

# Failed URL changes preserve binary, accepted state and live tunnel processes.
cp /test/config/active.ini /test/active.saved
cp /test/config/activation-state /test/activation.saved
cp /test/state/bin/wstunnel /test/binary.saved
ft_pid=$(pid ft)
for endpoint in failure bad redirect-http; do
    BINARY=$endpoint apply && fail "failed download accepted: $endpoint"
    grep -q '^KO download-failed$' /test/apply.out || fail 'download failure not reported'
    cmp /test/active.saved /test/config/active.ini || fail 'failed update changed active configuration'
    cmp /test/activation.saved /test/config/activation-state || fail 'failed update changed accepted URLs'
    cmp /test/binary.saved /test/state/bin/wstunnel || fail 'failed update removed old binary'
    [ "$(pid ft)" = "$ft_pid" ] || fail 'failed download disrupted tunnel'
done
cmp /test/draft.ini /test/config/desired.ini || fail 'failed draft not retained as desired'
ok 'failed/invalid/downgraded URL updates preserve working state and retain failed desired'
applied
[ "$(pid ft)" = "$ft_pid" ] || fail 'unchanged configuration restarted clients'
ok 'resubmitting the accepted configuration does not restart clients'

STORAGE=persistent applied
[ -x /test/config/bin/wstunnel ] || fail 'persistent binary missing'
"$W" shutdown
rm -rf /test/state
"$W" daemon --background
wait_running ft
ok 'persistent storage survives runtime loss'

# Boot download retries must actually recover after WAN restoration.
: > /test/wan-up
BINARY=flaky applied
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
ok 'boot download schedules bounded retries and actually recovers on WAN restoration'

before=$(head -n 1 /test/config/current)
printf 'blocked runtime directory\n' > /test/state/tunnels/localfail
BINARY=flaky EXTRA='[tunnel localfail]
server=main
listen=19009
target=localhost
port=80
' apply && fail 'worker launch failure accepted'
[ ! -e /test/config/tunnels/localfail ] && [ "$(head -n 1 /test/config/current)" = "$before" ] || fail 'worker launch failure not rolled back'
rm /test/state/tunnels/localfail
wait_running ft
"$W" status | grep -q '^Supervisor: running$' || fail 'rollback did not recover supervisor'
ok 'local worker launch failure restores configuration and supervisor'

mkdir -p /test/foreign
ln -s /test/foreign /test/linked
expect_fail env WTCTL_STATE_DIR=/test/linked "$W" status
expect_fail env WTCTL_STATE_DIR=/test/config "$W" status
mkdir -p /test/legacy-config/servers
printf '/test/legacy-config/applied/old\n' > /test/legacy-config/current
expect_fail env WTCTL_CONFIG_DIR=/test/legacy-config WTCTL_STATE_DIR=/test/legacy-state "$W" status
grep -q 'Legacy record-based configuration is not supported' /test/command.out || fail 'legacy installation not reported'
ok 'symlink and path overlap fail closed; legacy record-only installation rejected'

"$W" uninstall --yes
[ -f /test/config/active.ini ] && [ ! -e /test/state ] || fail 'uninstall preservation'
"$W" uninstall --purge --yes
[ ! -e /test/config ] || fail 'purge'
ok 'uninstall and explicit purge'
sh /work/tests/shutdown-race.sh
ok 'shutdown racing init-system TERM'
sh /work/tests/startup.sh
ok 'startup adapters, ownership safeguards, uninstall and no-parameter installer'
printf '\n%s fixture groups passed; physical qualification still required.\n' "$checks"
