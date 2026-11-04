# Control configuration qualification

The netcat path is implemented, but is not yet a production-qualified device
release. Do not interpret parser/fixture coverage as physical-hardware approval.

## Automated checks

- `make check`: shell syntax, ShellCheck, INI validation, Python helper tests.
- `make test`: BusyBox nc baseline, INI activation/protocol tests, and legacy
  regression fixtures.
- `make integration`: also runs pinned wstunnel v11 with verified TLS, all four
  ordinary tunnel modes, candidate confirmation through a real reverse tunnel,
  GET ACTIVE, and the remote control-disable success response.

Allow at least ten minutes for a full run. Confirmation-timeout coverage alone
waits the real 60-second deadline; legacy WAN recovery and rollback checks also
wait for real process and retry deadlines.

## Outstanding qualification

- Physical OpenWrt/BusyBox nc variant, resource use, 64 KiB streamed input timing,
  procd restart behavior, reboot, and WAN outage recovery.
- Installer `--config` end-to-end checks for each boot adapter (the existing
  adapter/legacy installer suite does not cover the new INI installer branch).
- Full software-update matrix over remote control: both URLs independently and
  together, storage transitions, post-replacement confirmation and rollback.
- Resource exhaustion and extended concurrent-submission stress. Job directories
  currently remain in runtime storage for diagnostics; retention is not bounded.
- The receiver uses two fixed loopback ports (8099/8100). Local port conflicts
  and nonstandard nc builds need qualification before deployment.

Power-loss/crash-atomic software rollback is intentionally not promised. The
activation coordinator must remain alive for best-effort executable rollback.
