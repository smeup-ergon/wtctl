#!/bin/sh
# OpenWrt applets/boot registration only; not procd supervision, downloads or hardware acceptance.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
docker run --rm --platform linux/amd64 --entrypoint /bin/sh -v "$ROOT:/work:ro" \
    openwrt/rootfs:x86-64-22.03.4 -c '
set -e
export WTCTL_CONFIG_DIR=/test/config WTCTL_STATE_DIR=/test/state
/work/wtctl doctor
/work/wtctl init
/work/wtctl server add test --endpoint wss://example.com
/work/wtctl tunnel add test --server test --listen 19001 --target localhost --port 80
/work/wtctl apply
/work/wtctl daemon --background
sleep 2
/work/wtctl status
/work/wtctl shutdown
(
    unset WTCTL_CONFIG_DIR WTCTL_STATE_DIR
    # Normal boot creates this runtime directory; the unbooted rootfs does not.
    mkdir -p /var/lock
    sh /work/scripts/install.sh --yes --startup openwrt
    rm -f /var/lock/procd_wtctl.lock
    /usr/sbin/wtctl doctor > /test/boot.enabled
    grep -Fq "Boot integration: openwrt — enabled" /test/boot.enabled
    test ! -e /var/lock/procd_wtctl.lock
    /etc/init.d/wtctl disable
    /usr/sbin/wtctl doctor > /test/boot.disabled
    grep -Fq "Boot integration: openwrt — disabled" /test/boot.disabled
    /usr/sbin/wtctl startup enable openwrt --yes
    /usr/sbin/wtctl doctor > /test/boot.reenabled
    grep -Fq "Boot integration: openwrt — enabled" /test/boot.reenabled
    # No procd instance is running in this rootfs: remove only test registration.
    /etc/init.d/wtctl disable
    rm /etc/init.d/wtctl
    /usr/sbin/wtctl uninstall --purge --yes
)
printf "OpenWrt 22.03.4 userland and boot registration smoke passed (not hardware qualification).\n"
'
