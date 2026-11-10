# Control configuration qualification

The ssh/dropbear control path is implemented, but is not yet a production-qualified device
release. Do not interpret parser/fixture coverage as physical-hardware approval.

## Automated checks

- `make check`: shell syntax, ShellCheck, INI validation, Python helper tests.
- `make test`: dropbear receiver and stalled-request checks, INI activation/protocol tests, lifecycle
  fixtures driven by `wtctl apply`, and the no-parameter installer.
- `make integration`: also runs pinned wstunnel v11 with verified TLS, all four
  ordinary tunnel modes, candidate confirmation through a real reverse tunnel,
  GET ACTIVE, and the remote control-disable success response.
- `make compose-test`: isolated containers with the official wstunnel v11.1.0
  server, verified WSS and path-prefix rejection, HTTPS software sources, and a
  plain OpenSSH operator. Covers no-parameter installation followed by apply,
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
netcat and stalled-request checks. (Historical: this run predates the dropbear
receiver.)

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

Open design limits found: manager replacement stopped the supervisor, leaving
control unavailable for about 25 s at 0.3 CPU emulated. Since 0.3.0 the
supervisor re-executes in place and the installer handoff no longer exists; the
outage has not been remeasured.
Activation compile/validation runs about 1,000 shell commands. Both need
measurement on target hardware.

### 2026-11-06: physical GL-AR300M

Device: GL-AR300M, OpenWrt 22.03.4 `r20123-38ccc47687`, ath79/nand, dropbear
2022.82, 59 MiB `/tmp`, 1.5 MiB overlay. Software: wstunnel 11.0.0 MIPS32r2 musl
soft-float (12,889,164 bytes). Server: wstunnel v11.1.0 on the workstation LAN,
verified TLS with a disposable CA, path-prefix restriction; operator OpenSSH
without keys. Installed from a copied release; no packages, firewall or
network settings were changed and the device was purged afterwards with
`/etc/passwd` and `/etc/config/*` identical to the baseline.

Passed on hardware: installer, rerun refusal, sample rejection, procd
ownership and supervisor respawn; first apply with real download and PENDING
(31–49 s); old receiver and local apply cannot confirm; real 60 s timeout
rollback; confirmation over ssh through the reverse tunnel; all four tunnel
modes (TCP 4 MiB echo, UDP 16 datagrams) after every stage; remote GET/GET
ACTIVE/STATUS (1.2–1.8 s); framing rejections; tunnel-only edit keeping
untouched client PIDs; exact 64 KiB PUT (18 s); wrong-prefix candidate rollback;
client crash respawn; 20 s server outage (control back 7.5 s after restart);
control-port migration both ways; wstunnel URL updates and unconfirmed-update
rollback; remote control disable/local re-enable; main SSH refuses the
blank-password account; software reboot with RAM re-download, control and four
tunnels back about 118 s after kernel start, using the active rather than a
failed desired configuration. Resident memory: supervisor 1.4 MiB, receiver
about 1 MiB, each wstunnel client about 9 MiB.

The first run failed on storage exhaustion (see [VALIDATION.md](VALIDATION.md)).
After the fixes the hardware regression passed: three unconfirmed first applies
and a fourth confirmed one, three updates and two rolled-back updates with no
retained staged copies (`/tmp` free returned to about 45 MiB after each),
`storage=persistent` refused with `KO insufficient-space` and the overlay
unchanged, remote disable replying `OK 0` and removing the account, and the
supervisor resuming 13.5 s after its pausing coordinator was killed. The final
build (manager SHA256 `57eacc8a…c39c5a1`) also reports that loss as
`failed activation-process-lost`, releases the lost job's staged download
(14.4 s to recovery, `/tmp` free unchanged) and accepts a following update.

A same-listener candidate (changed server settings or software with the same
server port) can drop the submitting session before `PENDING` is written, as
documented in [CONTROL.md](CONTROL.md); poll STATUS and confirm.

### 2026-11-09/10: power-cycle, WAN loss and sustained load on GL-AR300M

Same device and software as above, release `07b8ee1` (manager SHA256
`57eacc8a…c39c5a1`), installed from a copied release on a purged device.
Evidence: [2026-11-10-hardware-qualification.json](evidence/2026-11-10-hardware-qualification.json).
All local suites passed on the same commit: `make check`, 23 fixture groups,
`make integration`, `make openwrt-smoke`, `make compose-test` (29 groups),
`make reliability-test` (5 rounds, 20 groups) and `make stress-test`
(10 rounds, 35 groups).

Passed on hardware (2026-11-10 run; the 2026-11-09 run matched):

- Install and first apply confirmed over ssh in 44 s; all four tunnel modes.
- 120 s server outage during operation (device-local nft drop) with the RAM
  wstunnel binary deleted: binary re-downloaded and control back 7.9 s after
  the outage ended (4.8 s on 2026-11-09); traffic in all four modes.
- Reverse UDP, the 0.1.0 intermittency: 10 × 500 datagrams, none lost; forward
  UDP 5/5. No client restarts.
- Boot with the server unreachable for 180 s: supervisor retried the download,
  control recovered 53 s after the block lifted, traffic in all four modes.
- Owner-operated power-cycle (new boot ID, RAM marker gone): procd started
  the supervisor 91 s after boot, the binary was re-downloaded to RAM, control
  and all four tunnels ran by 119 s; accepted configuration and receiver
  account intact.

Sustained load (30 min of a continuous reverse TCP echo stream, repeated 4 MiB
forward TCP echoes and a 100-datagram reverse UDP probe every minute), three
runs:

| Run | Reverse TCP | Forward TCP | Reverse UDP probes | CPU avg |
|---|---|---|---|---|
| 2026-11-09 | 472 MB, no error | 110 ok, 2 failed | 27 ok, 2 failed | 98.9% |
| 2026-11-09 retry | 472 MB, no error | 110 ok, 1 failed (ssh login refused) | 29 ok | 98.7% |
| 2026-11-10, echoes run on device | 482 MB, no error | 117 ok, 0 failed | 29 ok, 1 failed | 99.7% |

These UDP probe failures are classified as a **device resource limit, not a
wtctl defect**. The single MIPS core was saturated throughout; TCP stayed
error-free once forward echoes no longer depended on new ssh logins; no client
restarted, the supervisor logged nothing, there was no OOM and control kept
serving the accepted configuration; idle reverse UDP lost nothing. UDP is not
retransmitted, so a saturated relay drops datagrams. This load is above what
the GL-AR300M sustains; it is not an error budget for faster devices.

The device clock was about 9 h 50 min slow during the run; a certificate valid
only from the current time was rejected and the first apply rolled back on
confirmation timeout, as designed. Devices need a correct clock (NTP) or
certificates whose validity covers the clock skew.

## Outstanding qualification

- Sustained load on devices with more CPU headroom than the GL-AR300M.
- Real boot-manager ownership, respawn and boot ordering under actual procd,
  systemd and SysV environments. The Compose adapter doubles execute the real
  daemon but do not qualify those init implementations.
- Native target ABI and interoperability with different upstream software
  releases. Compose software variants are byte-distinct fixtures based on the
  same real v11.1.0 static executable; they do not test version interoperability.
- Resource exhaustion and extended concurrent-submission stress. Finished job
  directories keep only small diagnostic records (staged software is released);
  their count is not bounded.
- The receiver uses two fixed loopback ports (8099/8100). Local port conflicts
  and dropbear builds other than 2022.82/2024.85/2024.86 need qualification.

Power-loss/crash-atomic software rollback is intentionally not promised. The
activation coordinator must remain alive for best-effort executable rollback.
