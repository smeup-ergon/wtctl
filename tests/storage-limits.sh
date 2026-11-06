#!/bin/sh
# Disposable fixture: staged-software retention, full runtime/persistent storage
# and the rollback that follows. Run with small tmpfs mounts at /test/state and
# /test/config (see tests/run.sh). Regressions for the 2026-11-06 GL-AR300M run.
# shellcheck disable=SC2015 # A && B || fail guards are intentional.
set -eu
export WTCTL_CONFIG_DIR=/test/config WTCTL_STATE_DIR=/test/state
mkdir -p /test/www
W=/test/manager
cp /work/wtctl "$W"; chmod 700 "$W"
cp "$W" /test/www/manager
cp /fixture /test/www/fixture
# A valid ELF padded to 3 MiB: trailing bytes do not affect loading.
{ cat /fixture; head -c 3145728 /dev/zero; } > /test/www/large
openssl req -x509 -newkey rsa:2048 -nodes -keyout /test/www/key.pem -out /test/www/cert.pem -days 1 -subj /CN=localhost -addext subjectAltName=DNS:localhost >/dev/null 2>&1
export CURL_CA_BUNDLE=/test/www/cert.pem
python3 /work/tests/https-server.py /test/www & server=$!
cleanup() { "$W" shutdown >/dev/null 2>&1 || :; kill "$server" 2>/dev/null || :; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; "$W" status >&2 || :; tail -30 /test/state/events >&2 || :; exit 1; }
checks=0
ok() { checks=$((checks+1)); printf 'ok %s - %s\n' "$checks" "$1"; }
send() { dbclient -y -y -T -p "$1" wtctl@127.0.0.1 x 2>/dev/null; }
free_kib() { df -Pk "$1" | awk 'END {print $4}'; }
staged() { find /test/state -path '/test/state/job.*' \( -name 'binary-*' -o -name 'manager-*' \) ! -name '*-path' ! -name '*-global' | wc -l; }
draft() {
    printf '[wtctl]\nformat=1\nurl=https://localhost:18888/manager\n'
    printf 'wstunnel_url=https://localhost:18888/%s\nstorage=%s\nmax_kib=4096\nreserve_kib=1024\n' "$1" "${STORAGE:-ram}"
    printf '[control]\nenabled=%s\nserver=main\nbind=127.0.0.1\nlisten=28099\n' "${CONTROL:-false}"
    printf '[server main]\nendpoint=wss://example.com\n'
    printf '[tunnel ssh]\nserver=main\nlisten=2222\ntarget=localhost\nport=22\n'
}
sleep 1
"$W" _bootstrap https://localhost:18888/manager >/dev/null
"$W" daemon --background

# 1. Finished activations release staged software. Three successive real
# replacements of a 3 MiB binary must not accumulate copies in runtime storage.
for revision in 1 2 3; do
    draft "large?rev=$revision" > /test/draft
    "$W" apply /test/draft | grep -qx 'OK 0' || fail "apply rev=$revision"
done
[ "$(staged)" = 0 ] || fail "finished jobs retain $(staged) staged software copies"
ok 'finished activations release staged software copies'

# 2. Activation does not need a second full copy on the runtime filesystem.
# Fill the 12 MiB state tmpfs until only download space (4096+1024 KiB) and
# less than another full copy remain beyond it.
used=$(du -k /test/state/bin/wstunnel | cut -f1)
filler=$(( $(free_kib /test/state) - 4096 - 1024 - used/2 ))
[ "$filler" -gt 0 ] && dd if=/dev/zero of=/test/state/filler bs=1024 count="$filler" 2>/dev/null
draft 'large?rev=4' > /test/draft
"$W" apply /test/draft | grep -qx 'OK 0' || fail 'replacement without space for duplicate copies'
cmp /test/www/large /test/state/bin/wstunnel || fail 'replacement binary mismatch'
rm -f /test/state/filler
ok 'replacement renames the staged download instead of copying it again'

# 3. Persistent storage is checked against its own filesystem before anything
# changes: the small config tmpfs cannot hold the binary.
cp /test/config/active.ini /test/active.saved
cp /test/config/activation-state /test/activation.saved
cp /test/state/bin/wstunnel /test/binary.saved
# Leave less configuration space than the 3 MiB binary plus its reserve.
surplus=$(( $(free_kib /test/config) - 3072 ))
[ "$surplus" -le 0 ] || dd if=/dev/zero of=/test/config/filler bs=1024 count="$surplus" 2>/dev/null
before=$(free_kib /test/config)
STORAGE=persistent draft 'large?rev=4' > /test/draft
reply=$("$W" apply /test/draft || :)
[ "$reply" = 'KO insufficient-space' ] || fail "persistent overflow reply: $reply"
[ ! -e /test/config/bin/wstunnel ] && [ -z "$(ls /test/config/bin 2>/dev/null)" ] || fail 'partial persistent binary left'
[ "$(free_kib /test/config)" -ge "$((before-8))" ] || fail 'persistent check consumed configuration space'
cmp /test/active.saved /test/config/active.ini && cmp /test/activation.saved /test/config/activation-state || fail 'accepted state changed'
cmp /test/binary.saved /test/state/bin/wstunnel || fail 'RAM binary changed'
"$W" status | grep -q '^ssh  *running' || fail 'tunnel not running after rejected persistent update'
rm -f /test/config/filler
ok 'persistent update rejected for lack of flash space without writing or disruption'

# 4. A persistent replacement that hits ENOSPC mid-copy rolls back without
# stalling the supervisor or losing the control record. The configuration
# filesystem is separate from runtime staging, so the binary is copied.
draft 'large?rev=5' > /test/draft
CONTROL=true draft 'large?rev=4' > /test/enabled
"$W" apply /test/enabled | grep -qx 'PENDING confirmation-required' || fail 'enable control'
receiver=$(awk -F= '$1=="receiver" {print $2}' /test/config/control)
attempt=0
until printf 'STATUS\n' | send "$receiver" | grep -qx awaiting-confirmation; do
    attempt=$((attempt+1)); [ "$attempt" -lt 20 ] || fail 'candidate receiver'; sleep 1
done
{ printf 'PUT %s\n' "$(wc -c < /test/enabled)"; cat /test/enabled; } | send "$receiver" | grep -qx 'OK 0' || fail 'confirm control'
grep -q '^wtctl::0:0:wtctl control receiver:' /etc/passwd || fail 'receiver account missing'
cp /test/config/active.ini /test/active.saved
# Fill the config filesystem completely, then request a persistent update whose
# space check passes only because the filler is removed after the check: emulate
# ENOSPC at the copy by filling just after the coordinator starts.
STORAGE=persistent CONTROL=true draft 'large?rev=6' > /test/full
# The coordinator pauses the supervisor only after its space check passed and
# before copying: fill the configuration filesystem in that window.
pauses=$(grep -c 'supervisor request [^ ]* pause$' /test/state/events || :)
# Like the device, space returns once rollback discards the partial candidate.
rollbacks=$(grep -c 'rollback begin' /test/state/events || :)
( n=0; while [ "$(grep -c 'supervisor request [^ ]* pause$' /test/state/events || :)" -le "$pauses" ]; do
      n=$((n+1)); [ "$n" -lt 1200 ] || exit 1; sleep 0.1; done
  dd if=/dev/zero of=/test/config/filler bs=1024 2>/dev/null || :
  n=0; until [ "$(grep -c 'rollback begin' /test/state/events || :)" -gt "$rollbacks" ]; do
      n=$((n+1)); [ "$n" -lt 1200 ] || break; sleep 0.1; done
  rm -f /test/config/filler ) &
filler_pid=$!
reply=$("$W" apply /test/full || :)
wait "$filler_pid" || :
[ "$reply" = 'KO activation-failed' ] || fail "full-filesystem reply: $reply"
attempt=0
until "$W" status | grep -q '^ssh  *running'; do
    attempt=$((attempt+1)); [ "$attempt" -lt 30 ] || fail 'supervisor stalled after full-filesystem rollback'; sleep 1
done
"$W" status | grep -q '^Control: running' || fail 'control not restored after rollback'
[ -f /test/config/control ] && grep -qx 'enabled=true' /test/config/control || fail 'control record lost in rollback'
grep -q '^wtctl::0:0:wtctl control receiver:' /etc/passwd || fail 'receiver account lost'
cmp /test/active.saved /test/config/active.ini || fail 'accepted configuration changed'
[ -z "$(ls /test/config/bin 2>/dev/null)" ] || fail 'partial persistent binary left after rollback'
ok 'full filesystem during activation: rollback restores control, tunnels and records'

# 5. Disabling control afterwards replies and removes the account.
{ printf 'PUT %s\n' "$(wc -c < /test/draft)"; cat /test/draft; } | send "$receiver" > /test/reply
grep -qx 'OK 0' /test/reply || fail "disable reply: $(cat /test/reply)"
attempt=0
while grep -q '^wtctl:' /etc/passwd; do attempt=$((attempt+1)); [ "$attempt" -lt 15 ] || fail 'account kept after disable'; sleep 1; done
ok 'control disable after a failed rollback replies and removes the account'

# 6. An activation coordinator killed while the supervisor is paused does not
# leave the supervisor paused.
pauses=$(grep -c 'supervisor request [^ ]* pause$' /test/state/events || :)
draft 'large?rev=7' > /test/draft
"$W" apply /test/draft > /test/kill.out 2>&1 & applier=$!
attempt=0
until [ "$(grep -c 'supervisor request [^ ]* pause$' /test/state/events || :)" -gt "$pauses" ]; do
    attempt=$((attempt+1)); [ "$attempt" -lt 150 ] || fail 'pause not observed'; sleep 0.2
done
coordinator=$(awk -F= '$1=="pid" {print $2}' "$(cat /test/state/latest-job)/coordinator")
kill -KILL "$coordinator"
wait "$applier" || :
attempt=0
until grep -q 'supervisor resume orphaned-pause' /test/state/events && "$W" status | grep -q '^ssh  *running'; do
    attempt=$((attempt+1)); [ "$attempt" -lt 30 ] || fail 'supervisor stayed paused after coordinator loss'; sleep 1
done
grep -qx 'failed activation-process-lost' /test/state/activation || fail "stale activation status: $(cat /test/state/activation)"
[ "$(staged)" = 0 ] || fail 'lost coordinator left staged software'
ok 'supervisor resumes when the pausing coordinator dies'
printf '%s storage-limit checks passed.\n' "$checks"
