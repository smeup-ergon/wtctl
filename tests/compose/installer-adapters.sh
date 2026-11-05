#!/bin/sh
# Disposable Compose device ONLY. Not a physical-boot qualification.
# Invoke after acceptance.reset_device(), before scenarios, or after a final reset:
# docker compose -p "$WTCTL_TEST_PROJECT" -f tests/compose/compose.yaml \
#   exec -T device sh /work/tests/compose/installer-adapters.sh
# Requires root, pristine /etc/wtctl, /tmp/wtctl and /usr/sbin/wtctl,
# /work checkout, live sources:8443/{manager,binary}, curl, Python 3,
# BusyBox tools, and CURL_CA_BUNDLE=/lab/ca.pem. Never alters /lab/manager.
# The no-parameter installer detects its adapter; per-adapter detection
# markers are created here and removed afterwards.
set -eu
umask 077

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$*"; }

[ "$(id -u)" = 0 ] || fail 'requires root in the disposable device'
[ -f /.dockerenv ] && [ -f /work/scripts/install.sh ] && [ -f /lab/ca.pem ] ||
    fail 'requires the Compose lab device container'
[ "${CURL_CA_BUNDLE:-}" = /lab/ca.pem ] || fail 'CURL_CA_BUNDLE must be /lab/ca.pem'
for path in /etc/wtctl /tmp/wtctl /usr/sbin/wtctl /etc/init.d/wtctl \
    /etc/systemd/system/wtctl.service /etc/rc.common /etc/openwrt_release \
    /etc/rc2.d/S99wtctl /etc/rc.d/S99wtctl /etc/rc.d/K15wtctl /run/systemd/system; do
    [ ! -e "$path" ] && [ ! -L "$path" ] || fail "reset device first: $path exists"
done

LAB_MATRIX=$(mktemp -d /tmp/wtctl-installer-adapters.XXXXXX)
export LAB_MATRIX
mkdir -p "$LAB_MATRIX/bin" /etc/init.d /etc/systemd/system /etc/rc2.d /etc/rc.d
PATH=$LAB_MATRIX/bin:$PATH
export PATH

clean_install() {
    if [ -x /usr/sbin/wtctl ]; then
        /usr/sbin/wtctl shutdown || return 1
        /usr/sbin/wtctl status > "$LAB_MATRIX/stopped.log"
        grep -q '^Supervisor: stopped$' "$LAB_MATRIX/stopped.log" || return 1
    fi
    for managed in /etc/init.d/wtctl /etc/systemd/system/wtctl.service; do
        if [ -e "$managed" ]; then
            grep -q '^# Managed by wtctl$' "$managed" || return 1
            rm -f "$managed"
        fi
    done
    rm -f /etc/rc2.d/S99wtctl /etc/rc.d/S99wtctl /etc/rc.d/K15wtctl
    # These exact installation paths belong only to this disposable test device.
    rm -rf /etc/wtctl /tmp/wtctl
    rm -f /usr/sbin/wtctl "$LAB_MATRIX/systemd.enabled"
}
select_adapter() {
    rm -f /etc/rc.common /etc/openwrt_release; rm -rf /run/systemd
    case "$1" in
        openwrt)
            cp "$LAB_MATRIX/rc.common" /etc/rc.common
            printf '# Test-only Compose OpenWrt adapter prerequisite\n' > /etc/openwrt_release;;
        systemd) mkdir -p /run/systemd/system;;
    esac
}
finish() {
    result=$?
    trap - EXIT
    if [ "$result" != 0 ]; then
        for log in "$LAB_MATRIX"/*.log; do
            [ ! -f "$log" ] || { printf '\n--- %s ---\n' "$log" >&2; cat "$log" >&2; }
        done
    fi
    if clean_install; then
        rm -f /etc/rc.common /etc/openwrt_release; rm -rf /run/systemd
        rm -rf "$LAB_MATRIX"
    else
        printf 'Cleanup refused: shutdown/ownership check failed; reset device. Logs: %s\n' "$LAB_MATRIX" >&2
        result=1
    fi
    exit "$result"
}
trap finish EXIT
trap 'exit 130' INT TERM HUP

# TEST-ONLY SysV registration shim: creates owned start link, never boots init.
cat > "$LAB_MATRIX/bin/update-rc.d" <<'SH'
#!/bin/sh
set -eu
printf 'sysv %s\n' "$*" >> "$LAB_MATRIX/registration.log"
case "$*" in
    'wtctl defaults') ln -sf /etc/init.d/wtctl /etc/rc2.d/S99wtctl;;
    '-f wtctl remove') rm -f /etc/rc2.d/S99wtctl;;
    *) exit 1;;
esac
SH

# TEST-ONLY systemctl shim: registration is simulated; ExecStart runs for real
# and its PID stands in for the systemd-owned service process.
cat > "$LAB_MATRIX/bin/systemctl" <<'SH'
#!/bin/sh
set -eu
printf 'systemd %s\n' "$*" >> "$LAB_MATRIX/registration.log"
case "$*" in
    daemon-reload) ;;
    'enable wtctl') : > "$LAB_MATRIX/systemd.enabled";;
    'disable --now wtctl') rm -f "$LAB_MATRIX/systemd.enabled"; /usr/sbin/wtctl shutdown;;
    'is-enabled wtctl.service')
        [ -f "$LAB_MATRIX/systemd.enabled" ] || exit 1
        printf 'enabled\n';;
    'start wtctl')
        command_line=$(sed -n 's/^ExecStart=//p' /etc/systemd/system/wtctl.service)
        [ "$command_line" = '/usr/sbin/wtctl daemon' ] || exit 1
        /usr/sbin/wtctl daemon </dev/null >> "$LAB_MATRIX/systemd-daemon.log" 2>&1 &
        printf '%s\n' "$!" > "$LAB_MATRIX/init.pid";;
    'stop wtctl') /usr/sbin/wtctl shutdown;;
    *) exit 1;;
esac
SH
chmod 755 "$LAB_MATRIX/bin/update-rc.d" "$LAB_MATRIX/bin/systemctl"

# TEST-ONLY rc.common/procd shim. The generated adapter is sourced unchanged;
# procd's command parameter starts the real foreground daemon in the background.
cat > "$LAB_MATRIX/rc.common" <<'SH'
#!/bin/sh
# Test-only Compose rc.common shim, NOT OpenWrt/procd boot coverage.
set -eu
adapter=$1
action=$2
procd_open_instance() { :; }
procd_set_param() {
    case "$1" in
        command)
            shift
            [ "$*" = '/usr/sbin/wtctl daemon' ] || exit 1
            "$@" </dev/null >> "$LAB_MATRIX/openwrt-daemon.log" 2>&1 &
            printf '%s\n' "$!" > "$LAB_MATRIX/init.pid";;
        respawn|term_timeout|stdout|stderr) :;;
        *) exit 1;;
    esac
}
procd_close_instance() { :; }
# shellcheck disable=SC1090
. "$adapter"
printf 'openwrt %s\n' "$action" >> "$LAB_MATRIX/registration.log"
case "$action" in
    enable)
        ln -sf /etc/init.d/wtctl "/etc/rc.d/S${START}wtctl"
        ln -sf /etc/init.d/wtctl "/etc/rc.d/K${STOP}wtctl";;
    disable) rm -f "/etc/rc.d/S${START}wtctl" "/etc/rc.d/K${STOP}wtctl";;
    start) start_service;;
    stop) /usr/sbin/wtctl shutdown;;
    *) exit 1;;
esac
SH

cat > "$LAB_MATRIX/valid.ini" <<'INI'
[wtctl]
format=1
url=https://sources:8443/manager
wstunnel_url=https://sources:8443/binary
storage=ram
[control]
enabled=false
server=primary
[server primary]
endpoint=wss://wstunnel:8080
auth=path
prefix=test-secret-prefix
ca=/lab/ca.pem
INI

install_plain() { sh /work/scripts/install.sh > "$LAB_MATRIX/install.log" 2>&1; }
apply_config() {
    cp "$1" /etc/wtctl/wtctl.ini
    /usr/sbin/wtctl apply /etc/wtctl/wtctl.ini > "$LAB_MATRIX/apply.log" 2>&1
}
daemon_pid() { sed -n 's/^pid=//p' /tmp/wtctl/daemon; }
wait_running() {
    count=0
    while :; do
        /usr/sbin/wtctl status > "$LAB_MATRIX/status.log"
        if grep -q '^Supervisor: running$' "$LAB_MATRIX/status.log"; then break; fi
        count=$((count + 1))
        [ "$count" -lt 20 ] || fail 'generated adapter did not start the real supervisor'
        sleep 1
    done
    /usr/sbin/wtctl _ready
}
assert_stopped() {
    /usr/sbin/wtctl status > "$LAB_MATRIX/status.log"
    grep -q '^Supervisor: stopped$' "$LAB_MATRIX/status.log" || fail 'adapter stop left supervisor running'
}
assert_accepted() {
    cmp "$LAB_MATRIX/valid.ini" /etc/wtctl/desired.ini
    cmp "$LAB_MATRIX/valid.ini" /etc/wtctl/active.ini
    cmp /etc/wtctl/current /etc/wtctl/accepted-current
    python3 - <<'PY'
from pathlib import Path
import subprocess

binary = Path('/tmp/wtctl/bin/wstunnel')
assert binary.read_bytes()[:4] == b'\x7fELF', 'accepted binary is not ELF'
assert binary.read_bytes() == Path('/lab/binary').read_bytes(), 'not the lab real binary'
result = subprocess.run([str(binary), '--version'], capture_output=True, check=True, timeout=10)
assert b'wstunnel' in result.stdout.lower(), result
assert not list(Path('/etc/wtctl/tunnels').glob('*')), 'unexpected ordinary tunnel'
assert not Path('/tmp/wtctl/tunnels/__control').exists(), 'disabled control was started'
PY
}

# No detectable init system: refuse before changing anything.
select_adapter none
mv "$LAB_MATRIX/bin/update-rc.d" "$LAB_MATRIX/update-rc.d.hidden"
mv /usr/sbin/update-rc.d /usr/sbin/update-rc.d.hidden
if install_plain; then refused=0; else refused=1; fi
mv /usr/sbin/update-rc.d.hidden /usr/sbin/update-rc.d
mv "$LAB_MATRIX/update-rc.d.hidden" "$LAB_MATRIX/bin/update-rc.d"
[ "$refused" = 1 ] || fail 'installer accepted a device without init system'
grep -q 'No supported init system' "$LAB_MATRIX/install.log" || fail 'missing init system not reported'
[ ! -e /usr/sbin/wtctl ] && [ ! -e /etc/wtctl ] || fail 'refused install changed the device'
pass 'installer without supported init system changes nothing'

for adapter in sysv openwrt systemd; do
    select_adapter "$adapter"
    : > "$LAB_MATRIX/registration.log"; rm -f "$LAB_MATRIX/init.pid"
    install_plain || fail "$adapter install failed"
    grep -q "with $adapter boot startup" "$LAB_MATRIX/install.log" || fail "$adapter not detected"
    case "$adapter" in
        openwrt) grep -qx 'openwrt start' "$LAB_MATRIX/registration.log" || fail 'installer did not start through OpenWrt adapter';;
        systemd) grep -qx 'systemd start wtctl' "$LAB_MATRIX/registration.log" || fail 'installer did not start through systemd';;
    esac
    wait_running
    grep -q REPLACE-ME /etc/wtctl/wtctl.ini || fail 'sample configuration missing'
    [ ! -e /etc/wtctl/active.ini ] || fail 'installer activated a configuration'
    if install_plain; then fail 'installer rerun accepted'; fi
    grep -q 'already installed' "$LAB_MATRIX/install.log" || fail 'rerun refusal not reported'
    owner=$(daemon_pid)
    [ ! -f "$LAB_MATRIX/init.pid" ] || [ "$owner" = "$(cat "$LAB_MATRIX/init.pid")" ] || fail 'supervisor is not the init-started process'
    # The lab manager URL differs from the installed one: apply replaces the
    # manager while the init-owned supervisor remains the same process.
    apply_config "$LAB_MATRIX/valid.ini" || fail "$adapter first apply failed"
    grep -q '^OK 0$' "$LAB_MATRIX/apply.log" || fail "$adapter activation not accepted"
    assert_accepted
    grep -q 'supervisor reexec' /tmp/wtctl/events || fail 'manager replacement did not re-exec the supervisor'
    [ "$(daemon_pid)" = "$owner" ] || fail 'manager replacement escaped init ownership'
    case "$adapter" in
        sysv)
            grep -qx 'sysv wtctl defaults' "$LAB_MATRIX/registration.log"
            grep -qx '# Default-Start: 2 3 4 5' /etc/init.d/wtctl
            grep -q '/usr/sbin/wtctl daemon --background' /etc/init.d/wtctl
            /etc/init.d/wtctl stop
            assert_stopped
            /etc/init.d/wtctl start;;
        openwrt)
            grep -qx 'openwrt enable' "$LAB_MATRIX/registration.log"
            grep -qx '#!/bin/sh /etc/rc.common' /etc/init.d/wtctl
            grep -qx 'USE_PROCD=1' /etc/init.d/wtctl
            grep -q 'procd_set_param command /usr/sbin/wtctl daemon' /etc/init.d/wtctl
            /etc/init.d/wtctl stop
            assert_stopped
            /etc/init.d/wtctl start;;
        systemd)
            grep -qx 'systemd daemon-reload' "$LAB_MATRIX/registration.log"
            grep -qx 'systemd enable wtctl' "$LAB_MATRIX/registration.log"
            grep -qx 'ExecStart=/usr/sbin/wtctl daemon' /etc/systemd/system/wtctl.service
            grep -qx 'WantedBy=multi-user.target' /etc/systemd/system/wtctl.service
            systemctl stop wtctl
            assert_stopped
            systemctl start wtctl;;
    esac
    wait_running
    assert_accepted
    /usr/sbin/wtctl doctor > "$LAB_MATRIX/doctor.log"
    case "$adapter" in
        sysv) grep -q 'Boot integration: sysv .* registered (start links found)' "$LAB_MATRIX/doctor.log";;
        *) grep -q "Boot integration: $adapter .* enabled" "$LAB_MATRIX/doctor.log";;
    esac
    cat "$LAB_MATRIX/registration.log"
    grep 'Boot integration:' "$LAB_MATRIX/doctor.log"
    /usr/sbin/wtctl uninstall --purge --yes > "$LAB_MATRIX/uninstall.log"
    grep -q "Removed $adapter boot integration" "$LAB_MATRIX/uninstall.log" || fail "$adapter uninstall kept boot integration"
    for path in /etc/init.d/wtctl /etc/systemd/system/wtctl.service /etc/rc2.d/S99wtctl /etc/rc.d/S99wtctl /usr/sbin/wtctl /etc/wtctl; do
        [ ! -e "$path" ] && [ ! -L "$path" ] || fail "$adapter uninstall left $path"
    done
    pass "$adapter install: idle init-owned service; manager-replacing apply keeps init ownership; uninstall removes boot (init SHIM)"
    clean_install || fail "$adapter shutdown/cleanup failed"
done

# First-apply download failure retains a runnable bootstrap and failed desired.
select_adapter sysv
sed 's|wstunnel_url=https://sources:8443/binary|wstunnel_url=https://sources:8443/missing|' \
    "$LAB_MATRIX/valid.ini" > "$LAB_MATRIX/unavailable.ini"
install_plain || fail 'sysv install failed'
if apply_config "$LAB_MATRIX/unavailable.ini"; then fail 'missing binary accepted'; fi
grep -q '^KO download-failed$' "$LAB_MATRIX/apply.log"
cmp /work/wtctl /usr/sbin/wtctl
cmp "$LAB_MATRIX/unavailable.ini" /etc/wtctl/desired.ini
[ ! -e /etc/wtctl/active.ini ] || fail 'download failure published active INI'
cmp /etc/wtctl/current /etc/wtctl/accepted-current
python3 - <<'PY'
from pathlib import Path

snapshot = Path(Path('/etc/wtctl/accepted-current').read_text().strip())
assert snapshot.is_dir(), 'bootstrap snapshot missing'
assert {p.name for p in snapshot.iterdir()} == {'global'}, 'bootstrap contains tunnels/control'
PY
/etc/init.d/wtctl stop
assert_stopped
/etc/init.d/wtctl start
wait_running
[ ! -e /etc/wtctl/active.ini ] || fail 'bootstrap restart activated failed desired'
cmp "$LAB_MATRIX/unavailable.ini" /etc/wtctl/desired.ini
pass 'sysv unavailable binary retains bootstrap and desired, no active, restart safe'
printf 'Installer adapter matrix passed (registration/init shims, not real boot).\n'
