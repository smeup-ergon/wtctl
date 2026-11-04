#!/bin/sh
# Disposable Compose device ONLY. Not a physical-boot qualification.
# Invoke after acceptance.reset_device(), before scenarios, or after a final reset:
# docker compose -p "$WTCTL_TEST_PROJECT" -f tests/compose/compose.yaml \
#   exec -T device sh /work/tests/compose/installer-adapters.sh
# Requires root, pristine /etc/wtctl, /tmp/wtctl and /usr/sbin/wtctl,
# /work checkout, live sources:8443/{manager,binary}, curl, Python 3,
# BusyBox tools, and CURL_CA_BUNDLE=/lab/ca.pem. Never alters /lab/manager.
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
    /etc/rc2.d/S99wtctl /etc/rc.d/S99wtctl /etc/rc.d/K15wtctl; do
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
finish() {
    result=$?
    trap - EXIT
    if [ "$result" != 0 ]; then
        for log in "$LAB_MATRIX"/*.log; do
            [ ! -f "$log" ] || { printf '\n--- %s ---\n' "$log" >&2; cat "$log" >&2; }
        done
    fi
    if clean_install; then
        rm -f /etc/rc.common /etc/openwrt_release
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
[ "$*" = 'wtctl defaults' ] || exit 1
ln -sf /etc/init.d/wtctl /etc/rc2.d/S99wtctl
SH

# TEST-ONLY systemctl shim: registration is simulated; ExecStart runs for real.
cat > "$LAB_MATRIX/bin/systemctl" <<'SH'
#!/bin/sh
set -eu
printf 'systemd %s\n' "$*" >> "$LAB_MATRIX/registration.log"
case "$*" in
    daemon-reload) ;;
    'enable wtctl') : > "$LAB_MATRIX/systemd.enabled";;
    'is-enabled wtctl.service')
        [ -f "$LAB_MATRIX/systemd.enabled" ] || exit 1
        printf 'enabled\n';;
    'start wtctl')
        command_line=$(sed -n 's/^ExecStart=//p' /etc/systemd/system/wtctl.service)
        [ "$command_line" = '/usr/sbin/wtctl daemon' ] || exit 1
        /usr/sbin/wtctl daemon </dev/null >> "$LAB_MATRIX/systemd-daemon.log" 2>&1 &
        printf '%s\n' "$!" > "$LAB_MATRIX/systemd.pid";;
    'stop wtctl') /usr/sbin/wtctl shutdown;;
    *) exit 1;;
esac
SH
chmod 755 "$LAB_MATRIX/bin/update-rc.d" "$LAB_MATRIX/bin/systemctl"

# TEST-ONLY rc.common/procd shim. The generated adapter is sourced unchanged;
# procd's command parameter starts the real foreground daemon in the background.
cat > /etc/rc.common <<'SH'
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
            printf '%s\n' "$!" > "$LAB_MATRIX/openwrt.pid";;
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
    start) start_service;;
    stop) /usr/sbin/wtctl shutdown;;
    *) exit 1;;
esac
SH
printf '# Test-only Compose OpenWrt adapter prerequisite\n' > /etc/openwrt_release

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

install_config() {
    sh /work/scripts/install.sh --yes --config "$1" --startup "$2" \
        > "$LAB_MATRIX/install.log" 2>&1
}
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
    cmp "${1:-$LAB_MATRIX/valid.ini}" /etc/wtctl/desired.ini
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

# Validation must precede manager installation AND boot registration.
sed 's/format=1/format=99/' "$LAB_MATRIX/valid.ini" > "$LAB_MATRIX/invalid.ini"
: > "$LAB_MATRIX/registration.log"
if install_config "$LAB_MATRIX/invalid.ini" sysv; then fail 'invalid INI accepted'; fi
[ ! -e /usr/sbin/wtctl ] || fail 'invalid INI installed manager'
[ ! -e /etc/wtctl/desired.ini ] || fail 'invalid INI persisted desired'
[ ! -e /etc/init.d/wtctl ] || fail 'invalid INI installed startup adapter'
[ ! -s "$LAB_MATRIX/registration.log" ] || fail 'invalid INI registered startup'
pass 'sysv invalid INI rejected before installation or registration'

for adapter in sysv openwrt systemd; do
    expected_desired=$LAB_MATRIX/valid.ini
    : > "$LAB_MATRIX/registration.log"
    install_config "$LAB_MATRIX/valid.ini" "$adapter" || fail "$adapter --config install failed"
    grep -q '^OK 0$' "$LAB_MATRIX/install.log" || fail "$adapter activation not accepted"
    assert_accepted
    case "$adapter" in
        openwrt) grep -qx 'openwrt start' "$LAB_MATRIX/registration.log" || fail 'installer did not start through OpenWrt adapter';;
        systemd) grep -qx 'systemd start wtctl' "$LAB_MATRIX/registration.log" || fail 'installer did not start through systemd';;
    esac
    if [ "$adapter" = sysv ]; then
        # Rerun with a failed draft after a distinguishable accepted manager.
        # The installer must not preempt URL-driven executable rollback.
        sed 's/VERSION=0.2.0/VERSION=0.2.0-preserved/' /usr/sbin/wtctl > "$LAB_MATRIX/old-manager"
        chmod 700 "$LAB_MATRIX/old-manager"
        cp "$LAB_MATRIX/old-manager" /usr/sbin/wtctl
        /usr/sbin/wtctl --version | grep -q 'preserved' || fail 'distinguishable manager is not executable'
        sed 's|wstunnel_url=https://sources:8443/binary|wstunnel_url=https://sources:8443/missing|' \
            "$LAB_MATRIX/valid.ini" > "$LAB_MATRIX/failed-upgrade.ini"
        if install_config "$LAB_MATRIX/failed-upgrade.ini" sysv; then fail 'failed reinstall accepted'; fi
        cmp "$LAB_MATRIX/old-manager" /usr/sbin/wtctl || fail 'installer overwrote accepted manager before activation'
        cmp "$LAB_MATRIX/valid.ini" /etc/wtctl/active.ini
        expected_desired=$LAB_MATRIX/failed-upgrade.ini
        assert_accepted "$expected_desired"
        pass 'failed INI reinstall preserves distinguishable accepted manager'
    fi
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
    assert_accepted "$expected_desired"
    /usr/sbin/wtctl doctor > "$LAB_MATRIX/doctor.log"
    case "$adapter" in
        sysv) grep -q 'Boot integration: sysv .* registered (start links found)' "$LAB_MATRIX/doctor.log";;
        *) grep -q "Boot integration: $adapter .* enabled" "$LAB_MATRIX/doctor.log";;
    esac
    cat "$LAB_MATRIX/registration.log"
    grep 'Boot integration:' "$LAB_MATRIX/doctor.log"
    pass "$adapter pristine --config install: accepted real ELF, correct generated adapter, real daemon stop/start (init SHIM)"
    clean_install || fail "$adapter shutdown/cleanup failed"
done

# First-install download failure retains a runnable bootstrap and failed desired.
sed 's|wstunnel_url=https://sources:8443/binary|wstunnel_url=https://sources:8443/missing|' \
    "$LAB_MATRIX/valid.ini" > "$LAB_MATRIX/unavailable.ini"
if install_config "$LAB_MATRIX/unavailable.ini" sysv; then fail 'missing binary accepted'; fi
grep -q '^KO download-failed$' "$LAB_MATRIX/install.log"
[ -x /usr/sbin/wtctl ] || fail 'download failure lost bootstrap manager'
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
grep -qx 'sysv wtctl defaults' "$LAB_MATRIX/registration.log"
/etc/init.d/wtctl stop
assert_stopped
/etc/init.d/wtctl start
wait_running
[ ! -e /etc/wtctl/active.ini ] || fail 'bootstrap restart activated failed desired'
cmp "$LAB_MATRIX/unavailable.ini" /etc/wtctl/desired.ini
pass 'sysv unavailable binary retains bootstrap and desired, no active, restart safe'
printf 'Installer adapter matrix passed (registration/init shims, not real boot).\n'
