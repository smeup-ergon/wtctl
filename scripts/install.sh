#!/bin/sh
# Explicit local installation; boot integration is opt-in and never starts service.
set -eu
umask 077
usage() { printf 'Usage: scripts/install.sh --yes [--startup openwrt|systemd|sysv | --no-startup] (as root)\n'; }
approved=0
startup_mode=prompt
adapter=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --yes) approved=1;;
        --startup)
            [ "$startup_mode" = prompt ] || { usage >&2; exit 1; }
            shift
            [ "$#" -gt 0 ] || { usage >&2; exit 1; }
            case "$1" in openwrt|systemd|sysv) adapter=$1;; *) usage >&2; exit 1;; esac
            startup_mode=enable;;
        --no-startup)
            [ "$startup_mode" = prompt ] || { usage >&2; exit 1; }
            startup_mode=skip;;
        --help|-h) usage; exit 0;;
        *) usage >&2; exit 1;;
    esac
    shift
done
[ "$approved" = 1 ] || { usage >&2; exit 1; }
[ "$(id -u)" = 0 ] || { printf 'Run as root.\n' >&2; exit 1; }
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TARGET=/usr/sbin/wtctl
[ ! -L /usr ] && [ ! -L /usr/sbin ] && [ ! -L "$TARGET" ] || { printf 'Refusing a symlink installation path.\n' >&2; exit 1; }
if [ -e "$TARGET" ]; then
    grep -q '^# wtctl: root-operated, POSIX-shell wstunnel client manager for Linux.$' "$TARGET" || { printf 'Refusing to overwrite an unrelated executable.\n' >&2; exit 1; }
    "$TARGET" shutdown
fi
mkdir -p /usr/sbin
TEMP=$TARGET.new.$$
trap 'rm -f "$TEMP"' EXIT
trap 'exit 130' INT TERM
cp "$ROOT/wtctl" "$TEMP"
chmod 755 "$TEMP"
mv "$TEMP" "$TARGET"
printf 'Installed %s.\n' "$TARGET"
if [ "$startup_mode" = prompt ]; then
    if [ -t 0 ] && [ -t 1 ]; then
        if [ -f /etc/openwrt_release ] && [ -f /etc/rc.common ]; then adapter=openwrt
        elif [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then adapter=systemd
        elif command -v update-rc.d >/dev/null 2>&1 || [ -d /etc/rc2.d ] || [ -d /etc/rc.d/rc2.d ]; then adapter=sysv
        fi
        if [ -n "$adapter" ]; then printf 'Enable wtctl at boot using %s? [y/N] ' "$adapter"
        else printf 'Enable wtctl at boot? [y/N] '; fi
        answer=
        if IFS= read -r answer; then
            case "$answer" in y|Y|yes|YES) startup_mode=enable;; *) startup_mode=skip;; esac
        else startup_mode=skip; fi
        if [ "$startup_mode" = enable ] && [ -z "$adapter" ]; then
            printf 'Adapter (openwrt/systemd/sysv): '
            if IFS= read -r adapter; then
                case "$adapter" in openwrt|systemd|sysv) ;; '') startup_mode=skip;; *) printf 'Unknown startup adapter.\n' >&2; exit 1;; esac
            else startup_mode=skip; fi
        fi
    else
        startup_mode=skip
        printf 'Non-interactive install: boot integration is unchanged. Use --startup ADAPTER to opt in.\n'
    fi
fi
if [ "$startup_mode" = enable ]; then
    "$TARGET" startup enable "$adapter" --yes
    printf 'Boot integration configured using %s; run wtctl doctor to verify registration.\n' "$adapter"
    printf 'This does not start the service now. Enabled tunnels resume at boot after configuration is applied.\n'
else
    printf 'Boot integration unchanged.\n'
fi
printf 'Run wtctl doctor, then wtctl for guided setup.\n'
