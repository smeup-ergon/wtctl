#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# Freeze sources: shell scripts can be reopened while an agent edits the checkout.
# Never mix an in-flight fixture process with half-written source files.
snapshot=$(mktemp -d "${TMPDIR:-/tmp}/wtctl-tests.XXXXXXXX")
trap 'rm -rf "$snapshot"' EXIT
trap 'exit 130' HUP INT TERM
for item in wtctl Makefile README.md GLOSSARY.md scripts docs tests .dockerignore; do cp -R "$ROOT/$item" "$snapshot/"; done
ROOT=$snapshot
cd "$ROOT"
case "${1:-}" in ''|--integration|--all) ;; *) printf 'Usage: tests/run.sh [--integration|--all]\n' >&2; exit 1;; esac
# Fixture and pinned real binary are x86_64; emulation is acceptable for these tests,
# not evidence of CPU/ABI compatibility on any physical device.
docker build --platform linux/amd64 -f tests/Dockerfile -t wtctl-tests:local .
docker run --rm --platform linux/amd64 -v "$ROOT:/work:ro" --entrypoint /bin/sh wtctl-tests:local /work/tests/config-ini.sh
docker run --rm --platform linux/amd64 -v "$ROOT:/work:ro" --entrypoint /bin/sh wtctl-tests:local /work/tests/netcat-baseline.sh
docker run --rm --platform linux/amd64 -v "$ROOT:/work:ro" --entrypoint /bin/sh wtctl-tests:local /work/tests/control-timeout.sh
docker run --rm --platform linux/amd64 -v "$ROOT:/work:ro" --entrypoint /bin/sh wtctl-tests:local /work/tests/control-config.sh
if [ "${1:-}" != --integration ]; then docker run --rm --platform linux/amd64 -v "$ROOT:/work:ro" wtctl-tests:local; fi
if [ -n "${1:-}" ]; then
    docker build --platform linux/amd64 -f tests/Dockerfile.integration -t wtctl-traffic:local .
    docker run --rm --platform linux/amd64 -v "$ROOT:/work:ro" wtctl-traffic:local
fi
