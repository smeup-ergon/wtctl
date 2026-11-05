#!/bin/sh
# Disposable BusyBox/Linux activation and control receiver protocol checks.
set -eu
export WTCTL_CONFIG_DIR=/test/config WTCTL_STATE_DIR=/test/state
mkdir -p /test
cp /work/wtctl /test/manager
chmod 700 /test/manager
W=/test/manager
cp /fixture /test/fixture
openssl req -x509 -newkey rsa:2048 -nodes -keyout /test/key.pem -out /test/cert.pem -days 1 -subj /CN=localhost -addext subjectAltName=DNS:localhost >/dev/null 2>&1
export CURL_CA_BUNDLE=/test/cert.pem
python3 /work/tests/https-server.py /test & server=$!
cleanup() { "$W" shutdown >/dev/null 2>&1 || :; kill "$server" 2>/dev/null || :; }
# Operator client: unauthenticated SSH session carrying the raw protocol bytes.
send() { dbclient -y -y -T -p "$1" wtctl@127.0.0.1 x 2>/dev/null; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
sleep 1
cat > /test/draft <<'EOF'
[wtctl]
format=1
url=https://localhost:18888/manager
wstunnel_url=https://localhost:18888/binary
[control]
enabled=false
server=main
bind=127.0.0.1
listen=28099
[server main]
endpoint=wss://example.com
[tunnel ssh]
server=main
listen=2222
target=localhost
port=22
EOF
"$W" apply /test/draft | grep -qx 'OK 0'
cmp /test/draft /test/config/active.ini
printf 'ok - local activation and accepted state\n'
cp /test/draft /test/accepted
sed 's@18888/binary@18888/bad@' /test/draft > /test/bad
if "$W" apply /test/bad; then exit 1; fi
cmp /test/bad /test/config/desired.ini
cmp /test/accepted /test/config/active.ini
"$W" shutdown
"$W" daemon --background
cmp /test/accepted /test/config/active.ini
printf 'ok - failed desired retained; boot uses active\n'
sed 's@18888/manager@18888/bad@' /test/draft > /test/bad-manager
if "$W" apply /test/bad-manager; then exit 1; fi
cmp /test/accepted /test/config/active.ini
"$W" --version | grep -qx 0.3.0
printf 'ok - invalid manager update preserves installed executable\n'
sed 's/enabled=false/enabled=true/' /test/draft > /test/enabled
"$W" apply /test/enabled | grep -qx 'PENDING confirmation-required'
receiver=$(awk -F= '$1=="receiver" {print $2}' /test/config/control)
attempt=0
until printf 'STATUS\n' | send "$receiver" | grep -qx 'awaiting-confirmation'; do
    attempt=$((attempt+1)); [ "$attempt" -lt 20 ] || exit 1; sleep 1
done
{ printf 'PUT %s\n' "$(wc -c < /test/enabled)"; cat /test/enabled; } | send "$receiver" > /test/reply
grep -qx 'OK 0' /test/reply
cmp /test/enabled /test/config/active.ini
printf 'GET ACTIVE\n' | send "$receiver" > /test/get
tail -n +2 /test/get > /test/body
cmp /test/body /test/enabled
printf 'STATUS\n' | send "$receiver" > /test/reply
grep -qx idle /test/reply
printf 'PUT 65537\n' | send "$receiver" | grep -qx 'KO invalid-request'
"$W" status > /test/status
grep -q '^Control:' /test/status
if grep -q '^__control ' /test/status; then exit 1; fi
grep -q '^wtctl::0:0:wtctl control receiver:/:' /etc/passwd
printf 'ok - candidate confirmation over the dropbear receiver, reads, framing, receiver account, dedicated status\n'
# No control-affecting edit: no additional candidate confirmation.
sed 's/port=22/port=23/' /test/enabled > /test/tunnel-edit
cat /test/tunnel-edit | "$W" apply - | grep -qx 'OK 0'
cmp /test/tunnel-edit /test/config/active.ini
printf 'ok - streamed stdin and ordinary tunnel-only edits\n'
if "$W" tunnel remove ssh 2>/dev/null; then exit 1; fi
cp /test/config/active.ini /test/before-invalid
printf 'PUT 5\nabc' | send "$receiver" | grep -qx 'KO invalid-request'
cmp /test/before-invalid /test/config/active.ini
printf 'ok - truncated payload rejected and INI mutation interface enforced\n'
sed 's/listen=28099/listen=28100/' /test/tunnel-edit > /test/candidate
"$W" apply /test/candidate | grep -qx 'PENDING confirmation-required'
{ printf 'PUT %s\n' "$(wc -c < /test/candidate)"; cat /test/candidate; } | WTCTL_RECEIVER_PORT="$receiver" "$W" _handle | grep -qx 'PENDING confirmation-required'
cmp /test/tunnel-edit /test/config/active.ini
printf 'ok - identical bytes on old receiver cannot confirm candidate\n'
# A newer draft invalidates the previous candidate and activates serially.
sed 's/port=23/port=24/' /test/tunnel-edit > /test/newest
"$W" apply /test/newest | grep -qx 'OK 0'
cmp /test/newest /test/config/active.ini
printf 'ok - newer draft supersedes unconfirmed candidate\n'
sed 's/listen=28099/listen=28101/' /test/newest > /test/timeout
"$W" apply /test/timeout | grep -qx 'PENDING confirmation-required'
attempt=0
while ! grep -q '^failed confirmation-timeout$' /test/state/activation; do
    attempt=$((attempt+1)); [ "$attempt" -lt 90 ] || exit 1; sleep 1
done
cmp /test/newest /test/config/active.ini
cmp /test/timeout /test/config/desired.ini
printf 'ok - confirmation timeout restores accepted configuration\n'
{ printf 'PUT %s\n' "$(wc -c < /test/draft)"; cat /test/draft; } | send "$receiver" > /test/disabled-reply
grep -qx 'OK 0' /test/disabled-reply
attempt=0
while grep -q '^wtctl:' /etc/passwd; do
    attempt=$((attempt+1)); [ "$attempt" -lt 15 ] || exit 1; sleep 1
done
printf 'ok - control disable completes and removes the receiver account\n'
# A foreign wtctl account is never adopted or changed.
printf 'wtctl:x:1234:1234:administrator account:/home/wtctl:/bin/sh\n' >> /etc/passwd
cp /etc/passwd /test/passwd.foreign
if "$W" apply /test/enabled > /test/foreign.out; then exit 1; fi
grep -qx 'KO control-unavailable' /test/foreign.out
cmp /test/passwd.foreign /etc/passwd
sed -i '/^wtctl:x:1234:/d' /etc/passwd
printf 'ok - foreign wtctl account rejected and left untouched\n'
