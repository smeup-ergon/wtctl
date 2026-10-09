#!/bin/sh
# Isolated adapter-generation checks; real procd/systemd behavior is a hardware gate.
# shellcheck disable=SC2016
# Generated init scripts must contain literal shell expressions.
set -eu
cp /work/wtctl /usr/sbin/wtctl
chmod 755 /usr/sbin/wtctl
unset WTCTL_CONFIG_DIR WTCTL_STATE_DIR
mkdir -p /etc/init.d /etc/systemd/system
printf 'DISTRIB_ID=OpenWrt\n' > /etc/openwrt_release
# Test-only rc.common shim. It records registration, not procd lifecycle.
printf '#!/bin/sh\nscript=$1; shift; . "$script"\ncase "$1" in enable) touch /test/boot-enabled;; disable) rm -f /test/boot-enabled;; stop) /usr/sbin/wtctl shutdown;; esac\n' > /etc/rc.common
chmod 755 /etc/rc.common
/usr/sbin/wtctl init
/usr/sbin/wtctl startup install openwrt --yes
[ -f /test/boot-enabled ]
grep -q 'procd_set_param command /usr/sbin/wtctl daemon' /etc/init.d/wtctl
if /usr/sbin/wtctl startup install openwrt --yes >/dev/null 2>&1; then exit 1; fi
/usr/sbin/wtctl startup remove openwrt --yes
[ ! -e /etc/init.d/wtctl ] && [ ! -e /test/boot-enabled ]
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> /test/systemctl.calls\n' > /usr/bin/systemctl
chmod 755 /usr/bin/systemctl
/usr/sbin/wtctl startup install systemd --yes
grep -q '^ExecStart=/usr/sbin/wtctl daemon$' /etc/systemd/system/wtctl.service
grep -q '^enable wtctl$' /test/systemctl.calls
/usr/sbin/wtctl startup remove systemd --yes
[ ! -e /etc/systemd/system/wtctl.service ]
grep -q '^disable --now wtctl$' /test/systemctl.calls
/usr/sbin/wtctl startup install sysv --yes
grep -q 'daemon --background' /etc/init.d/wtctl
/usr/sbin/wtctl startup remove sysv --yes
[ ! -e /etc/init.d/wtctl ]
printf 'unrelated administrator file\n' > /etc/init.d/wtctl
if /usr/sbin/wtctl startup remove sysv --yes >/dev/null 2>&1; then exit 1; fi
grep -q '^unrelated administrator file$' /etc/init.d/wtctl
rm /etc/init.d/wtctl
/usr/sbin/wtctl uninstall --purge --yes
[ ! -e /usr/sbin/wtctl ]
# Verify the separate source installation helper does not register/start anything.
sh /work/scripts/install.sh --yes
[ -x /usr/sbin/wtctl ] && [ ! -e /etc/init.d/wtctl ]
/usr/sbin/wtctl uninstall --purge --yes
printf 'Startup adapter generation/ownership and installer checks passed.\n'
