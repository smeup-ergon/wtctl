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

An initial focused repeatability run on the same date completed five rounds of
server restart/reconnection, real software replacement with confirmation-timeout
rollback, and subsequent control-port migration in both directions (20 groups
including installation prechecks). All rounds passed and lab resources were
removed. `make check`, `make integration`, and all 27 `make test` fixture groups
also passed. This did **not** reproduce or establish the cause of the historical
failures. `make reliability-test` now provides a repeatable diagnostic path;
the extended version also includes TLS-rejected candidate supersession before
migration. No production reliability fix is claimed from these green runs.

The concurrent full Compose baseline also passed all 29 groups in project
`wtctl-acceptance-1793806312-87247`; its containers, network and volume were
removed. The extended 20-round diagnostic run is not included in this result.

The extended diagnostic run subsequently passed all **20 rounds / 65 groups**
in project `wtctl-acceptance-1793807314-93447`, finishing at
2026-11-04T16:57:35Z. Each round checked server reconnection, real software
replacement and timeout rollback, TLS-rejected candidate supersession, and
control-port migration out and back. All project containers, network and volume
were removed. Together with the initial five rounds this is repeatability
evidence, not a root-cause finding: the historical intermittent failures were
not reproduced, no production fix was made, and hardware/soak qualification
remains outstanding.

### 2026-11-05: emulation, stress lab and handler cost

The lab had been running under x86 emulation on an ARM host: `compose.yaml`
fixed `linux/amd64` and the host exported `DOCKER_DEFAULT_PLATFORM=linux/amd64`.
Measured cost of one INI validation: native ARM at 0.3 CPU 0.31 s; emulated x86
at 1 CPU 1.06 s, at 0.3 CPU 6.61 s. `run.sh` now selects the Docker host's native
platform and a checksum-pinned matching upstream v11.1.0 static executable;
`WTCTL_LAB_PLATFORM` forces another platform.

`make stress-test` (0.3 CPU, 40±30 ms delay, 1% loss on the device) failed twice
under emulation, with saved evidence:

1. Installer handoff: control replies stayed empty for 90 s. Under emulation at
   0.3 CPU, a single `GET ACTIVE` took 4.9 s, about 3 s of it in a header reader
   that forked several processes per byte. The handler-duration events were added
   after this run, so it is unproven that this exceeded the 10 s client deadline.
   wtctl now uses a feature-probed capped shell `read` (fallback: the byte reader),
   skips redundant `prepare` in the reader, and returns from `bounded` without a
   one-second poll. Measured at the same setting: header 3.1 s → 0.2 s, full
   `GET ACTIVE` 4.9 s → 1.7 s. Real nc checks still accept split and single-write
   PUT bodies and reject CRLF, control bytes and EOF before newline.
2. After the handler fix, a software rollback did not reach
   `awaiting-confirmation` within 90 s: 45 s elapsed between the PUT and
   `applying`, then 30 s pausing the supervisor. All stages were slow; there was
   no incorrect state transition.

Native results, all with resources removed:

- `make reliability-test`, 3 rounds (14 groups): passed.
- `make stress-test`, 10 rounds at 0.3 CPU / 40±30 ms / 1% loss (35 groups): passed.
- Full `make compose-test` with the same stress (29 groups): passed.
- 10 rounds at 0.15 CPU / 100±80 ms / 5% loss (35 groups): passed.

The full suite emulated as unthrottled x86 also passed all 29 groups. Therefore
emulation alone did not recreate the historical failures and is **not**
established as their cause. Those runs predated the handler change, so this is
not an exact recreation. Emulation combined with CPU limits did cause genuine
timeouts. Failure evidence is now retained in `tests/compose/artifacts/` and the
device keeps a bounded `/tmp/wtctl/events` trail.

Open design limits found: the installer handoff and manager replacement stop the
supervisor, leaving control unavailable for about 25 s at 0.3 CPU emulated.
Activation compile/validation runs about 1,000 shell commands. Both need
measurement on target hardware.

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
