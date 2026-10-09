#!/bin/sh
# Define the complete installer before executing it: safe to stream into sh.
# One repeatable setup: install, configure/update binary, register boot, start.
install_main() {
set -eu
umask 077
usage() {
    printf 'Usage: install.sh [--yes] [--url HTTPS_RAW_BINARY_URL] [--storage ram|persistent] [--startup openwrt|systemd|sysv] [--ref GIT_REF]\n'
}
# stdin contains shell source in curl | sh. Wizard input must come from the tty,
# but only after the entire function above/below has been parsed by the shell.
if [ ! -t 0 ] && [ -t 1 ] && (: </dev/tty) 2>/dev/null; then
    exec </dev/tty
fi
approved=0
adapter=
storage=
url=
ref=main
explicit_ref=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --yes) approved=1;;
        --url|--storage|--startup|--ref)
            option=$1; shift
            [ "$#" -gt 0 ] || { usage >&2; exit 1; }
            case "$option" in
                --url) url=$1;;
                --storage) case "$1" in ram|persistent) storage=$1;; *) usage >&2; exit 1;; esac;;
                --startup) case "$1" in openwrt|systemd|sysv) adapter=$1;; *) usage >&2; exit 1;; esac;;
                --ref)
                    case "$1" in ''|*[!A-Za-z0-9._-]*|.|..) usage >&2; exit 1;; esac
                    ref=$1; explicit_ref=1;;
            esac;;
        --help|-h) usage; exit 0;;
        *) usage >&2; exit 1;;
    esac
    shift
done
[ "$approved" = 1 ] || { [ -t 0 ] && [ -t 1 ]; } || { printf 'Unattended setup requires --yes.\n' >&2; usage >&2; exit 1; }
[ "$(id -u)" = 0 ] || { printf 'Run as root.\n' >&2; exit 1; }
[ -z "${WTCTL_CONFIG_DIR:-}" ] && [ -z "${WTCTL_STATE_DIR:-}" ] || { printf 'Device setup requires default config/state paths.\n' >&2; exit 1; }
ROOT=
# $0 is sh (not a script path) for a streamed installer. Never resolve it
# relative to the caller's directory, or accidentally install a local wtctl.
case "$0" in
    sh|*/sh|-sh) ;;
    *) ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd);;
esac
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
if [ "$explicit_ref" = 0 ] && [ -n "$ROOT" ] && [ -f "$ROOT/wtctl" ]; then
    cp "$ROOT/wtctl" "$TEMP"
else
    command -v curl >/dev/null 2>&1 || { printf 'Bootstrap requires curl with HTTPS and CA trust.\n' >&2; exit 1; }
    printf 'Fetching wtctl from smeup-ergon/wtctl (%s).\n' "$ref"
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 20 --max-time 60 --max-filesize 262144 \
        --output "$TEMP" "https://raw.githubusercontent.com/smeup-ergon/wtctl/$ref/wtctl"
fi
# Check the manager before invoking candidate code or replacing an installation.
if ! grep -q '^# wtctl: root-operated, POSIX-shell wstunnel client manager for Linux.$' "$TEMP" || ! sh -n "$TEMP"; then
    printf 'Invalid downloaded manager script.\n' >&2; exit 1
fi
chmod 755 "$TEMP"
if [ "$approved" != 1 ]; then
    "$TEMP" _approve || { printf 'Setup cancelled.\n'; exit 1; }
fi
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
}

# Parse exit on the same line before main redirects stdin to the terminal.
install_main "$@"; exit
