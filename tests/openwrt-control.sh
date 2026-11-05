#!/bin/sh
# Stock OpenWrt 22.03.4 userland: the real wtctl control receiver (dropbear,
# blank-password receiver account) without adding packages. Not a boot test.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
docker run --rm --platform linux/amd64 --entrypoint /bin/sh -v "$ROOT:/work:ro" \
    openwrt/rootfs:x86-64-22.03.4 -c '
set -e
export WTCTL_CONFIG_DIR=/test/config WTCTL_STATE_DIR=/test/state
mkdir -p /var/run /var/lock /test
W=/work/wtctl
send() { dbclient -y -y -T -p "$1" wtctl@127.0.0.1 x 2>/dev/null; }
$W doctor > /test/doctor || :
grep -q "Control receiver: dropbear" /test/doctor
$W _bootstrap https://example.com/wtctl
cp /etc/passwd /test/passwd.before
# Activate control without network access: seed the active INI, compiled
# records and accepted control the way a successful activation leaves them.
cat > /test/device.ini <<EOF
[wtctl]
format=1
url=https://example.com/wtctl
wstunnel_url=https://example.com/wstunnel
[control]
enabled=true
server=s
[server s]
endpoint=wss://example.com
EOF
cp /test/device.ini /test/config/desired.ini; cp /test/device.ini /test/config/active.ini
printf "enabled=true\nserver=s\nbind=::\nlisten=8099\nreceiver=28099\n" > /test/config/control
# The receiver and account are the units under test; run the receiver directly.
$W _receiver 28099 & receiver=$!
sleep 1
# Without the receiver account, the stock main dropbear policy applies: refused.
if printf "STATUS\n" | send 28099 | grep -q .; then exit 1; fi
printf "wtctl::0:0:wtctl control receiver:/:/bin/ash\n" >> /etc/passwd
[ "$(printf "STATUS\n" | send 28099)" = "$(printf "OK 5\nidle")" ]
printf "GET ACTIVE\n" | send 28099 > /test/get
tail -n +2 /test/get | cmp - /test/device.ini
printf "PUT 5\nabc" | send 28099 | grep -qx "KO invalid-request"
head -c 65537 /dev/zero | tr "\0" "#" > /test/big
{ printf "PUT 65537\n"; cat /test/big; } | send 28099 | grep -qx "KO invalid-request"
test -s /test/config/control_host_key
kill "$receiver"; wait "$receiver" 2>/dev/null || :
# uninstall removes only the owned account entry.
$W uninstall --purge --yes >/dev/null
cmp /test/passwd.before /etc/passwd
printf "OpenWrt 22.03.4 stock dropbear control receiver passed (STATUS, GET ACTIVE, framing, uninstall).\n"
'
