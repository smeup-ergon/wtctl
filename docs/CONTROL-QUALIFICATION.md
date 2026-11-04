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
- `make compose-test`: isolated containers with the official wstunnel v11.1.0
  server, verified WSS and path-prefix rejection, HTTPS software sources, and a
  plain BusyBox nc operator. Covers pristine `--config FILE` installation,
  candidate confirmation and supersession, exact 64 KiB framing, software URL
  changes independently/together, byte-distinct executable replacement/rollback,
  both storage transitions, outages, container restart recovery, and the
  control-disable success response. The final installer matrix exercises SysV,
  OpenWrt and systemd adapter scripts using explicit registration/init doubles.
  See [COMPOSE-ACCEPTANCE.md](COMPOSE-ACCEPTANCE.md) for scope and manual use.

Allow at least ten minutes for a full run. Confirmation-timeout coverage alone
waits the real 60-second deadline; legacy WAN recovery and rollback checks also
wait for real process and retry deadlines.

## Recorded acceptance result

On 2026-11-04, `make compose-test` completed all **29 acceptance groups** in
project `wtctl-acceptance-1793796419-77378`, including the final installer adapter
matrix. Project containers, network and volume were removed after completion.
The latest full regression run also passed all 27 fixture groups and the INI,
netcat and stalled-request checks.

This is one complete Compose pass, not a repeatability or soak qualification.
Earlier runs intermittently failed server reconnection and the post-rollback
control-port migration. Focused repeats passed, but those intermittent causes
have not been conclusively established; retain repeat-run coverage before
claiming deployment reliability.

## Outstanding qualification

- Physical OpenWrt/BusyBox nc variant, resource use, 64 KiB streamed input timing,
  procd restart behavior, reboot, and WAN outage recovery.
- Real boot-manager ownership, respawn and boot ordering under actual procd,
  systemd and SysV environments. The Compose adapter doubles execute the real
  daemon but do not qualify those init implementations.
- Native target ABI and interoperability with different upstream software
  releases. Compose software variants are byte-distinct fixtures based on the
  same real v11.1.0 static executable; they do not test version interoperability.
- Resource exhaustion and extended concurrent-submission stress. Job directories
  currently remain in runtime storage for diagnostics; retention is not bounded.
- The receiver uses two fixed loopback ports (8099/8100). Local port conflicts
  and nonstandard nc builds need qualification before deployment.

Power-loss/crash-atomic software rollback is intentionally not promised. The
activation coordinator must remain alive for best-effort executable rollback.
