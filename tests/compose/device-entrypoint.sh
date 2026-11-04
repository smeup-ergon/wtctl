#!/bin/sh
set -eu

# Container restart is not a real init boot. Reuse the installed, generated
# service script only after a successful install accepted a configuration.
if [ -f /etc/wtctl/accepted-current ] && [ -x /etc/init.d/wtctl ]; then
    /etc/init.d/wtctl start
fi

# The echo service keeps PID 1 alive and supplies reverse-tunnel destinations.
exec python3 /work/tests/compose/lab.py echo
