#!/bin/sh
# Static probe for the owner-approved GL-AR300M test device; not a manager dependency.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$ROOT/dist/test-tools"
docker run --rm --platform linux/amd64 -v "$ROOT/tests/net-probe.c:/source.c:ro" \
    -v "$ROOT/dist/test-tools:/output" --entrypoint /bin/sh \
    openwrt/sdk:ath79-nand-22.03.4 -ec '
export STAGING_DIR=/builder/staging_dir
compiler=$(find "$STAGING_DIR" -path "*/bin/mips-openwrt-linux-musl-gcc" -print -quit)
[ -n "$compiler" ] || { printf "MIPS SDK compiler not found\n" >&2; exit 1; }
"$compiler" -static -Os -Wall -Wextra -mips32r2 -msoft-float /source.c -o /output/net-probe
'
