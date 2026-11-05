#!/bin/sh
# OpenWrt applets/boot registration only; not procd supervision, downloads or hardware acceptance.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
docker run --rm --platform linux/amd64 --entrypoint /bin/sh -v "$ROOT:/work:ro" \
    openwrt/rootfs:x86-64-22.03.4 -c '
set -e
export WTCTL_CONFIG_DIR=/test/config WTCTL_STATE_DIR=/test/state
/work/wtctl doctor
/work/wtctl status
/work/wtctl _bootstrap https://example.com/wtctl
cat > /test/device.ini <<EOF
[wtctl]
format=1
url=https://example.com/wtctl
wstunnel_url=https://example.com/wstunnel
[control]
enabled=false
server=test
[server test]
endpoint=wss://example.com
[tunnel test]
server=test
listen=19001
target=localhost
port=80
EOF
/work/wtctl validate /test/device.ini
# No native client/downloader is provisioned in this unbooted rootfs. Activation
# must fail and keep the bootstrap instead of claiming local startup.
if /work/wtctl apply /test/device.ini; then exit 1; fi
test ! -e /test/config/active.ini
test ! -e /test/config/tunnels/test
/work/wtctl daemon --background
sleep 2
/work/wtctl status
/work/wtctl shutdown
(
    unset WTCTL_CONFIG_DIR WTCTL_STATE_DIR
    # Normal boot creates this runtime directory; the unbooted rootfs does not.
    mkdir -p /var/lock
    # Adapter-only smoke: a full install requires an approved native download.
    mkdir -p /usr/sbin
    cp /work/wtctl /usr/sbin/wtctl
    chmod 755 /usr/sbin/wtctl
    /usr/sbin/wtctl status >/dev/null
    /usr/sbin/wtctl _startup enable openwrt --yes
    rm -f /var/lock/procd_wtctl.lock
    /usr/sbin/wtctl doctor > /test/boot.enabled || :
    grep -Fq "Boot integration: openwrt — enabled" /test/boot.enabled
    test ! -e /var/lock/procd_wtctl.lock
    /etc/init.d/wtctl disable
    /usr/sbin/wtctl doctor > /test/boot.disabled || :
    grep -Fq "Boot integration: openwrt — disabled" /test/boot.disabled
    /usr/sbin/wtctl _startup enable openwrt --yes
    /usr/sbin/wtctl doctor > /test/boot.reenabled || :
    grep -Fq "Boot integration: openwrt — enabled" /test/boot.reenabled
    # uninstall removes the managed procd adapter and its registration.
    /usr/sbin/wtctl uninstall --purge --yes
    test ! -e /etc/init.d/wtctl
    test ! -e /usr/sbin/wtctl
)
printf "OpenWrt 22.03.4 userland and boot registration smoke passed (not hardware qualification).\n"
'
