#!/bin/sh
# One repeatable setup: install, configure/update binary, register boot, start.
set -eu
umask 077
usage() {
    printf 'Usage: scripts/install.sh --yes [--url HTTPS_RAW_BINARY_URL] [--storage ram|persistent] [--startup openwrt|systemd|sysv]\n'
}
approved=0
adapter=
storage=
url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --yes) approved=1;;
        --url|--storage|--startup)
            option=$1; shift
            [ "$#" -gt 0 ] || { usage >&2; exit 1; }
            case "$option" in
                --url) url=$1;;
                --storage) case "$1" in ram|persistent) storage=$1;; *) usage >&2; exit 1;; esac;;
                --startup) case "$1" in openwrt|systemd|sysv) adapter=$1;; *) usage >&2; exit 1;; esac;;
            esac;;
        --help|-h) usage; exit 0;;
        *) usage >&2; exit 1;;
    esac
    shift
done
[ "$approved" = 1 ] || { usage >&2; exit 1; }
[ "$(id -u)" = 0 ] || { printf 'Run as root.\n' >&2; exit 1; }
[ -z "${WTCTL_CONFIG_DIR:-}" ] && [ -z "${WTCTL_STATE_DIR:-}" ] || { printf 'Device setup requires default config/state paths.\n' >&2; exit 1; }
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TARGET=/usr/sbin/wtctl
[ ! -L /usr ] && [ ! -L /usr/sbin ] && [ ! -L "$TARGET" ] || { printf 'Refusing a symlink installation path.\n' >&2; exit 1; }
if [ -e "$TARGET" ]; then
    grep -q '^# wtctl: root-operated, POSIX-shell wstunnel client manager for Linux.$' "$TARGET" || { printf 'Refusing to overwrite an unrelated executable.\n' >&2; exit 1; }
fi
mkdir -p /usr/sbin
TEMP=$TARGET.new.$$
ADAPTER_FILE=$TARGET.adapter.$$
trap 'rm -f "$TEMP" "$ADAPTER_FILE"' EXIT
trap 'exit 130' INT TERM HUP
cp "$ROOT/wtctl" "$TEMP"
chmod 755 "$TEMP"
# Resolve boot requirements before changing an installation.
if [ -z "$adapter" ]; then
    if [ -f /etc/openwrt_release ] && [ -f /etc/rc.common ]; then adapter=openwrt
    elif [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then adapter=systemd
    elif command -v update-rc.d >/dev/null 2>&1; then adapter=sysv
    elif [ -t 0 ] && [ -t 1 ]; then
        (set -C; : > "$ADAPTER_FILE")
        "$TEMP" _adapter "$ADAPTER_FILE"
        adapter=$(head -n 1 "$ADAPTER_FILE")
    else
        printf 'Cannot detect boot adapter; supply --startup openwrt|systemd|sysv.\n' >&2; exit 1
    fi
fi
case "$adapter" in
    openwrt) [ -f /etc/openwrt_release ] && [ -f /etc/rc.common ] || { printf 'OpenWrt rc.common is required.\n' >&2; exit 1; };;
    systemd) command -v systemctl >/dev/null 2>&1 || { printf 'systemctl is required.\n' >&2; exit 1; };;
    sysv) command -v update-rc.d >/dev/null 2>&1 || { printf 'SysV automatic boot registration requires update-rc.d.\n' >&2; exit 1; };;
esac
"$TEMP" _check-startup "$adapter"
# Run candidate code first: failed downloads leave the installed manager intact.
"$TEMP" _setup "$storage" "$url"
# A candidate supervisor must exit before its executable path disappears.
# Transfer ownership to the installed executable and the init system.
"$TEMP" shutdown
mv "$TEMP" "$TARGET"
"$TARGET" startup enable "$adapter" --yes
case "$adapter" in
    openwrt|sysv) /etc/init.d/wtctl start;;
    systemd) systemctl start wtctl;;
esac
"$TARGET" _ready
printf 'Setup complete: %s, %s boot startup, all saved tunnels active.\n' "$TARGET" "$adapter"
printf 'Use wtctl for the menu, or wtctl status. Rerun setup with --url to update.\n'
