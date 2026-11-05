#!/bin/sh
# Own one disposable project; never target the user's manual lab.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
WTCTL_TEST_PROJECT="wtctl-acceptance-$(date +%s)-$$"
export WTCTL_TEST_PROJECT
# Emulated containers run many times slower and with erratic timing; the lab
# must measure wtctl, not the emulator. Override only to test another ABI.
if [ -z "${WTCTL_LAB_PLATFORM:-}" ]; then
    case "$(docker info --format '{{.Architecture}}')" in
        aarch64|arm64) WTCTL_LAB_PLATFORM=linux/arm64;;
        x86_64|amd64) WTCTL_LAB_PLATFORM=linux/amd64;;
        *) printf 'Unsupported Docker architecture; set WTCTL_LAB_PLATFORM\n' >&2; exit 3;;
    esac
fi
# A user-wide DOCKER_DEFAULT_PLATFORM would otherwise force emulation or
# conflict with the per-service platform; scope it to this lab only.
DOCKER_DEFAULT_PLATFORM=$WTCTL_LAB_PLATFORM
export WTCTL_LAB_PLATFORM DOCKER_DEFAULT_PLATFORM
printf 'Lab platform: %s\n' "$WTCTL_LAB_PLATFORM"
COMPOSE_FILES="-f $ROOT/tests/compose/compose.yaml"
[ "${WTCTL_STRESS:-0}" = 0 ] || COMPOSE_FILES="$COMPOSE_FILES -f $ROOT/tests/compose/stress.yaml"
# Failure evidence must outlive the disposable project and temporary files.
ARTIFACTS=${WTCTL_ARTIFACTS:-$ROOT/tests/compose/artifacts}/$WTCTL_TEST_PROJECT
# shellcheck disable=SC2086
compose() { docker compose -p "$WTCTL_TEST_PROJECT" $COMPOSE_FILES "$@"; }
cleanup() {
    result=$?
    trap - EXIT
    if [ "$result" != 0 ]; then
        mkdir -p "$ARTIFACTS"
        printf '%s\n' "$result" > "$ARTIFACTS/exit-status"
        compose ps -a > "$ARTIFACTS/ps.txt" 2>&1 || :
        compose logs --no-color --timestamps > "$ARTIFACTS/compose.log" 2>&1 || :
        compose exec -T device sh -c 'cat /tmp/wtctl/events.1 /tmp/wtctl/events 2>/dev/null' > "$ARTIFACTS/events.txt" 2>&1 || :
        # shellcheck disable=SC2016 # expanded by the device shell
        compose exec -T device sh -c 'for f in /tmp/wtctl/activation /tmp/wtctl/receiver /tmp/wtctl/previous-receiver /tmp/wtctl/pending /tmp/wtctl/latest-job /etc/wtctl/control /etc/wtctl/current /etc/wtctl/accepted-current; do echo "== $f"; cat "$f" 2>/dev/null; done; for j in /tmp/wtctl/job.*; do echo "== $j"; cat "$j/result" "$j/log" 2>/dev/null; done; for t in /tmp/wtctl/tunnels/*; do echo "== $t"; cat "$t/status" 2>/dev/null; done; /usr/sbin/wtctl status; ps -ef; cat /proc/net/tcp /proc/net/tcp6' > "$ARTIFACTS/device-state.txt" 2>&1 || :
        [ ! -f "${RUNNER_LOG:-}" ] || cp "$RUNNER_LOG" "$ARTIFACTS/runner.log"
        printf 'Failure artifacts: %s\n' "$ARTIFACTS" >&2
        tail -n 60 "$ARTIFACTS/events.txt" >&2 || :
    fi
    compose down --volumes --remove-orphans || :
    [ -z "${RUNNER:-}" ] || rm -f "$RUNNER"
    [ -z "${RUNNER_LOG:-}" ] || rm -f "$RUNNER_LOG"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
if ! compose build; then
    # Image build is infrastructure, not an acceptance verdict.
    printf 'Lab image build failed; no acceptance result.\n' >&2
    trap - EXIT; compose down --volumes --remove-orphans || :; exit 3
fi
compose up -d --wait
# Execute the same immutable runner source that was copied into the lab image.
# This avoids mixing a running image with concurrent checkout edits.
RUNNER=$(mktemp "${TMPDIR:-/tmp}/wtctl-compose-runner.XXXXXXXX")
RUNNER_LOG=$(mktemp "${TMPDIR:-/tmp}/wtctl-compose-log.XXXXXXXX")
compose cp operator:/work/tests/compose/acceptance.py "$RUNNER"
export WTCTL_COMPOSE_FILES="$COMPOSE_FILES"
# Preserve the runner exit status through tee.
{ python3 "$RUNNER" 2>&1; printf '%s\n' "$?" > "$RUNNER_LOG.status"; } | tee "$RUNNER_LOG"
status=$(cat "$RUNNER_LOG.status"); rm -f "$RUNNER_LOG.status"
[ "$status" = 0 ] || exit "$status"
