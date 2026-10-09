#!/bin/sh
# OpenWrt userland compatibility only; not procd, download, ABI or hardware acceptance.
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
printf "OpenWrt 22.03.4 userland smoke passed (not hardware qualification).\n"
'
