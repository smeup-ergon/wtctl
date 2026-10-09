#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
case "${1:-}" in ''|--integration|--all) ;; *) printf 'Usage: tests/run.sh [--integration|--all]\n' >&2; exit 1;; esac
# Fixture and pinned real binary are x86_64; emulation is acceptable for these tests,
# not evidence of CPU/ABI compatibility on any physical device.
docker build --platform linux/amd64 -f tests/Dockerfile -t wtctl-tests:local .
if [ "${1:-}" != --integration ]; then docker run --rm --platform linux/amd64 -v "$ROOT:/work:ro" wtctl-tests:local; fi
if [ -n "${1:-}" ]; then
    docker build --platform linux/amd64 -f tests/Dockerfile.integration -t wtctl-traffic:local .
    docker run --rm --platform linux/amd64 -v "$ROOT:/work:ro" wtctl-traffic:local
fi
