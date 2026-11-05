#!/bin/sh
# Define the complete installer before executing it: safe to stream into sh.
# First installation only: install the manager, write a sample configuration,
# register boot startup and start an idle supervisor. No parameters, no prompts.
install_main() {
set -eu
umask 077
[ "$#" = 0 ] || { printf 'Usage: install.sh (no parameters)\n' >&2; exit 1; }
[ "$(id -u)" = 0 ] || { printf 'Run as root.\n' >&2; exit 1; }
[ -z "${WTCTL_CONFIG_DIR:-}" ] && [ -z "${WTCTL_STATE_DIR:-}" ] || { printf 'Device setup requires default config/state paths.\n' >&2; exit 1; }
MANAGER_URL=https://raw.githubusercontent.com/smeup-ergon/wtctl/main/wtctl
TARGET=/usr/sbin/wtctl
CONFIG=/etc/wtctl/wtctl.ini
if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
    printf 'wtctl is already installed. Update it by changing url= in %s and running: wtctl apply %s\n' "$CONFIG" "$CONFIG" >&2
    exit 1
fi
ROOT=
# $0 is sh (not a script path) for a streamed installer. Never resolve it
# relative to the caller's directory, or accidentally install a local wtctl.
case "$0" in
    sh|*/sh|-sh) ;;
    *) ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd);;
esac
# Resolve boot requirements before changing anything.
if [ -f /etc/openwrt_release ] && [ -f /etc/rc.common ]; then adapter=openwrt
elif [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then adapter=systemd
elif command -v update-rc.d >/dev/null 2>&1; then adapter=sysv
else
    printf 'No supported init system found: OpenWrt (procd), systemd, or SysV with update-rc.d is required.\n' >&2
    exit 1
fi
[ ! -L /usr ] && [ ! -L /usr/sbin ] || { printf 'Refusing a symlink installation path.\n' >&2; exit 1; }
mkdir -p /usr/sbin
TEMP=$TARGET.new.$$
trap 'rm -f "$TEMP"' EXIT
trap 'exit 130' INT TERM HUP
if [ -n "$ROOT" ] && [ -f "$ROOT/wtctl" ]; then
    cp "$ROOT/wtctl" "$TEMP"
else
    command -v curl >/dev/null 2>&1 || { printf 'Bootstrap requires curl with HTTPS and CA trust.\n' >&2; exit 1; }
    printf 'Fetching %s\n' "$MANAGER_URL"
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 20 --max-time 60 --max-filesize 262144 \
        --output "$TEMP" "$MANAGER_URL"
fi
# Check the manager before invoking candidate code.
if ! grep -q '^# wtctl: root-operated, POSIX-shell wstunnel client manager for Linux.$' "$TEMP" || ! sh -n "$TEMP"; then
    printf 'Invalid downloaded manager script.\n' >&2; exit 1
fi
chmod 755 "$TEMP"
"$TEMP" _check-startup "$adapter"
mv "$TEMP" "$TARGET"
"$TARGET" _bootstrap "$MANAGER_URL"
if [ -e "$CONFIG" ]; then
    printf 'Keeping existing %s\n' "$CONFIG"
else
    cat > "$CONFIG.new.$$" <<EOF
# wtctl desired configuration. Replace every REPLACE-ME value, then run:
#   wtctl validate $CONFIG && wtctl apply $CONFIG
# Whole-line comments start with # or ;. Values are literal.

[wtctl]
format=1
# Changing either URL requests a software update on the next apply.
url=$MANAGER_URL
# Raw wstunnel executable for this device's architecture (HTTPS).
wstunnel_url=https://REPLACE-ME.invalid/wstunnel
# ram (re-downloaded after reboot) or persistent (stored in /etc/wtctl/bin).
storage=ram

[control]
# Remote configuration through a reverse tunnel; restrict the server-side
# port with a firewall. Set enabled=false to manage only locally.
enabled=true
server=primary
bind=::
listen=8099

[server primary]
endpoint=wss://REPLACE-ME.invalid
# none, path (with prefix=) or basic (with username= and password=).
auth=none
# ca=/etc/wtctl/server-ca.pem

# One section per ordinary tunnel; omitting a tunnel removes it.
# [tunnel ssh]
# server=primary
# direction=reverse
# protocol=tcp
# bind=127.0.0.1
# listen=2222
# target=localhost
# port=22
EOF
    mv "$CONFIG.new.$$" "$CONFIG"
    printf 'Wrote sample configuration %s\n' "$CONFIG"
fi
"$TARGET" _startup enable "$adapter" --yes
case "$adapter" in
    openwrt|sysv) /etc/init.d/wtctl start;;
    systemd) systemctl start wtctl;;
esac
"$TARGET" _ready
printf 'Installed %s with %s boot startup; the service is running idle.\n' "$TARGET" "$adapter"
printf 'Next: edit %s, then run: wtctl apply %s\n' "$CONFIG" "$CONFIG"
}

# Parse exit on the same line so a truncated stream cannot run partially.
install_main "$@"; exit
