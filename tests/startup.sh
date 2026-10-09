#!/bin/sh
# Isolated adapter-generation checks; real procd/systemd behavior is a hardware gate.
# shellcheck disable=SC2016
# Generated init scripts must contain literal shell expressions.
set -eu
cp /work/wtctl /usr/sbin/wtctl
chmod 755 /usr/sbin/wtctl
unset WTCTL_CONFIG_DIR WTCTL_STATE_DIR
mkdir -p /etc/init.d /etc/rc.d /etc/systemd/system
boot_report() {
    /usr/sbin/wtctl doctor > /test/doctor.out
    grep -Fq "$1" /test/doctor.out || { printf 'Missing doctor boot report: %s\n' "$1" >&2; exit 1; }
}
boot_report 'Boot integration: not installed'
printf 'DISTRIB_ID=OpenWrt\n' > /etc/openwrt_release
# Test-only rc.common shim: real registration links, no procd lifecycle.
cat > /etc/rc.common <<'RC_COMMON'
#!/bin/sh
script=$1; shift; . "$script"
case "$1" in
    enable)
        mkdir -p /etc/rc.d
        ln -sf ../init.d/wtctl "/etc/rc.d/S${START}wtctl"
        ln -sf ../init.d/wtctl "/etc/rc.d/K${STOP}wtctl"
        touch /test/boot-enabled;;
    enabled) touch /test/doctor-queried-init; test -f /test/boot-enabled;;
    disable) rm -f /test/boot-enabled /etc/rc.d/S*wtctl /etc/rc.d/K*wtctl;;
    stop) /usr/sbin/wtctl shutdown;;
esac
RC_COMMON
chmod 755 /etc/rc.common
/usr/sbin/wtctl init
/usr/sbin/wtctl startup install openwrt --yes
[ -f /test/boot-enabled ]
boot_report 'Boot integration: openwrt — enabled'
[ ! -e /test/doctor-queried-init ]
/etc/init.d/wtctl disable
boot_report 'Boot integration: openwrt — disabled'
cp /etc/init.d/wtctl /test/adapter.before
/usr/sbin/wtctl startup enable openwrt --yes
cmp /etc/init.d/wtctl /test/adapter.before
boot_report 'Boot integration: openwrt — enabled'
if /usr/sbin/wtctl startup enable sysv --yes >/dev/null 2>&1; then exit 1; fi
boot_report 'Boot integration: openwrt — enabled'
su -s /bin/sh nobody -c '/usr/sbin/wtctl doctor' > /test/doctor.nonroot
grep -Fq 'Boot integration: openwrt — enabled' /test/doctor.nonroot
chmod 700 /etc/rc.d
su -s /bin/sh nobody -c '/usr/sbin/wtctl doctor' > /test/doctor.restricted
grep -Fq 'Boot integration: openwrt — unknown (registration directory not accessible)' /test/doctor.restricted
chmod 755 /etc/rc.d
grep -q 'procd_set_param command /usr/sbin/wtctl daemon' /etc/init.d/wtctl
if /usr/sbin/wtctl startup install openwrt --yes >/dev/null 2>&1; then exit 1; fi
/usr/sbin/wtctl startup remove openwrt --yes
[ ! -e /etc/init.d/wtctl ] && [ ! -e /test/boot-enabled ]
cat > /usr/bin/systemctl <<'SYSTEMCTL'
#!/bin/sh
printf '%s\n' "$*" >> /test/systemctl.calls
case "$1" in
    enable) printf 'enabled\n' > /test/systemd.state;;
    disable) printf 'disabled\n' > /test/systemd.state;;
    is-enabled) cat /test/systemd.state; grep -q '^enabled$' /test/systemd.state;;
esac
SYSTEMCTL
chmod 755 /usr/bin/systemctl
/usr/sbin/wtctl startup install systemd --yes
grep -q '^ExecStart=/usr/sbin/wtctl daemon$' /etc/systemd/system/wtctl.service
grep -q '^enable wtctl$' /test/systemctl.calls
boot_report 'Boot integration: systemd — enabled'
printf 'disabled\n' > /test/systemd.state
boot_report 'Boot integration: systemd — disabled'
printf 'masked\n' > /test/systemd.state
boot_report 'Boot integration: systemd — masked'
printf 'unexpected query response\n' > /test/systemd.state
boot_report 'Boot integration: systemd — unknown (systemctl query failed)'
mv /usr/bin/systemctl /usr/bin/systemctl.hidden
boot_report 'Boot integration: systemd — unknown (systemctl unavailable)'
mv /usr/bin/systemctl.hidden /usr/bin/systemctl
/usr/sbin/wtctl startup remove systemd --yes
[ ! -e /etc/systemd/system/wtctl.service ]
grep -q '^disable --now wtctl$' /test/systemctl.calls
/usr/sbin/wtctl startup install sysv --yes
grep -q 'daemon --background' /etc/init.d/wtctl
boot_report 'Boot integration: sysv — not registered (manual boot hooks may exist)'
mkdir -p /etc/rc2.d
ln -s ../init.d/wtctl /etc/rc2.d/S99wtctl
boot_report 'Boot integration: sysv — registered (start links found)'
chmod 700 /etc/rc2.d
su -s /bin/sh nobody -c '/usr/sbin/wtctl doctor' > /test/doctor.sysv.restricted
grep -Fq 'Boot integration: sysv — unknown (registration directory not accessible)' /test/doctor.sysv.restricted
chmod 755 /etc/rc2.d
readlink_path=$(command -v readlink)
mv "$readlink_path" "$readlink_path.hidden"
boot_report 'Boot integration: sysv — unknown (readlink unavailable)'
mv "$readlink_path.hidden" "$readlink_path"
rm /etc/rc2.d/S99wtctl
/usr/sbin/wtctl startup remove sysv --yes
[ ! -e /etc/init.d/wtctl ]
printf 'unrelated administrator file\n' > /etc/init.d/wtctl
boot_report 'Boot integration: init script — unmanaged (left untouched)'
if /usr/sbin/wtctl startup enable sysv --yes >/dev/null 2>&1; then exit 1; fi
if /usr/sbin/wtctl startup remove sysv --yes >/dev/null 2>&1; then exit 1; fi
grep -q '^unrelated administrator file$' /etc/init.d/wtctl
rm /etc/init.d/wtctl
ln -s /test/missing-adapter /etc/init.d/wtctl
boot_report 'Boot integration: init script — unmanaged symlink (not inspected)'
if /usr/sbin/wtctl startup enable openwrt --yes >/dev/null 2>&1; then exit 1; fi
[ ! -e /test/missing-adapter ]
rm /etc/init.d/wtctl
/usr/sbin/wtctl uninstall --purge --yes
[ ! -e /usr/sbin/wtctl ]
# Verify the separate source installation helper does not register/start anything.
sh /work/scripts/install.sh --yes
[ -x /usr/sbin/wtctl ] && [ ! -e /etc/init.d/wtctl ]
/usr/sbin/wtctl uninstall --purge --yes
python3 /work/tests/installer.py
printf 'Startup adapter generation/ownership, doctor and installer checks passed.\n'
