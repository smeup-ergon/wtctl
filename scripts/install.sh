#!/bin/sh
# Explicit local installation; no package manager or startup changes.
set -eu
umask 077
[ "${1:-}" = --yes ] && [ "$#" = 1 ] || { printf 'Usage: scripts/install.sh --yes (as root)\n' >&2; exit 1; }
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
printf 'Installed %s. Run wtctl doctor, then wtctl for guided setup.\nStartup registration is separate and explicit.\n' "$TARGET"
