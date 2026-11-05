#!/bin/sh
set -eu

# Stress lab only: impair the device's egress (latency, jitter, loss).
if [ -n "${WTCTL_LAB_NETEM:-}" ]; then
    # shellcheck disable=SC2086
    tc qdisc replace dev eth0 root netem $WTCTL_LAB_NETEM
fi

# Container restart is not a real init boot. Reuse the installed, generated
# service script only after a successful install accepted a configuration.
if [ -f /etc/wtctl/accepted-current ] && [ -x /etc/init.d/wtctl ]; then
    /etc/init.d/wtctl start
fi

# The echo service keeps PID 1 alive and supplies reverse-tunnel destinations.
exec python3 /work/tests/compose/lab.py echo
