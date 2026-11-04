#!/bin/sh
# Own one disposable project; never target the user's manual lab.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
WTCTL_TEST_PROJECT="wtctl-acceptance-$(date +%s)-$$"
export WTCTL_TEST_PROJECT
compose() { docker compose -p "$WTCTL_TEST_PROJECT" -f "$ROOT/tests/compose/compose.yaml" "$@"; }
cleanup() {
    result=$?
    trap - EXIT
    if [ "$result" != 0 ]; then
        compose ps -a >&2 || :
        compose logs --no-color --tail 40 >&2 || :
        compose exec -T device sh -c 'cat /tmp/wtctl/activation /tmp/wtctl/job.*/log 2>/dev/null; /usr/sbin/wtctl status' >&2 || :
        compose exec -T device sh -c 'cat /tmp/wtctl/receiver /tmp/wtctl/tunnels/__control/status /tmp/wtctl/tunnels/__control/child 2>/dev/null; ps -ef; cat /proc/net/tcp /proc/net/tcp6' >&2 || :
    fi
    compose down --volumes --remove-orphans || :
    [ -z "${RUNNER:-}" ] || rm -f "$RUNNER"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
compose up -d --build --wait
# Execute the same immutable runner source that was copied into the lab image.
# This avoids mixing a running image with concurrent checkout edits.
RUNNER=$(mktemp "${TMPDIR:-/tmp}/wtctl-compose-runner.XXXXXXXX")
compose cp operator:/work/tests/compose/acceptance.py "$RUNNER"
export WTCTL_COMPOSE_FILE="$ROOT/tests/compose/compose.yaml"
python3 "$RUNNER"
rm -f "$RUNNER"
