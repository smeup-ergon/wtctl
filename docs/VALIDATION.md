# Validation and release gates

## Streamed single-command setup follow-up

`curl .../scripts/install.sh | sh` is covered by a real controlling-terminal
pipeline test from `/`, with the bootstrap GitHub responses mocked and binary
transfers using the verified local HTTPS fixture. Coverage includes single-key
approval/cancellation, storage/URL prompts through `/dev/tty`, automatic boot and
service startup, unattended flags, pinned refs, truncated streams, failed/invalid
manager downloads, staging cleanup and preservation of installed configurations
and running clients on bootstrap failures.

`make check`, the final `./tests/run.sh --all` (26 fixture groups plus 4 real
traffic checks), `make openwrt-smoke`, and `git diff --check` passed.
An earlier full run failed a pre-existing removal assertion based on `kill -0`;
a 10-iteration isolated retry/removal probe and the subsequent full run did not
reproduce it. The assertion now reports Linux process state on failure; no
lifecycle fix or identified root cause is claimed. This remains an unresolved
intermittent test signal, not proof of either a live orphan or a zombie. No
physical follow-up was performed and no published-main bootstrap test was run.
See [streamed setup evidence](evidence/streamed-setup-local.json).

## 0.2.0 original simplified lifecycle

This release changes the configuration schema and lifecycle. There are no existing
installations to migrate. New coverage exercises implicit mutations/rollback,
automatic startup of every saved tunnel, affected-only/shared-profile restart,
RAM/persistent boot recovery, nondestructive failed updates, supplied-URL replacement,
idempotent setup, automatic boot/service startup, single-key numeric/letter menus,
hidden secrets and terminal restoration on EOF/signals.

Local validation passed for this worktree: `make check` (syntax/ShellCheck,
6 historical-helper unit tests, Python AST parsing), `./tests/run.sh --all`
(26 fixture groups and 4 real verified-TLS traffic checks), `make openwrt-smoke`,
and `git diff --check`. Real PTYs cover numeric/letter choices without Enter,
invalid-key handling, missing-stty fallback, hidden secrets, and both menu and
password EOF/signal restoration. Init ownership in fixture tests uses shims;
the OpenWrt rootfs exercises actual adapter registration, not booted procd.
See [local evidence](evidence/simplification-local.json). No physical
0.2.0 acceptance is claimed. The older physical harnesses are version-gated before
device mutations/reboots because their disabled/draft/destructive-update assertions
are incompatible. Required new physical gates: full setup/service ownership, latest
saved settings across reboot/power cycle, WAN recovery, failed update rollback,
actual footprint/performance, and the unresolved reverse-UDP behavior. SIGKILL or
power loss during a multi-file transaction is not crash-atomic; qualify interruption
recovery separately before production use.

## Historical 0.1.0 development evidence

Executed locally in Docker on 2026-10-09, with isolated container configuration
and processes. Physical results are recorded separately below. Old-project
repository files were not changed.

| Check | Result | Scope |
| --- | --- | --- |
| `make check` | Passed | POSIX-sh syntax and ShellCheck; Python syntax, 4 restoration regressions and 2 UDP-result/exit regressions |
| `make test` | 38 grouped checks passed | Alpine 3.20 BusyBox shell, compiled ELF fixture, real curl against locally trusted HTTPS |
| `make integration` | 4 traffic checks passed | Real upstream wstunnel v11.0.0 linux/amd64, verified WSS and custom CA/path auth, forward/reverse TCP/UDP echoed payloads |
| `make openwrt-smoke` | Passed | OpenWrt 22.03.4 x86-64: applets/config/idle supervisor and actual rc.common registration/doctor checks |
| `make dist` | Passed | Rebuilt after shutdown fix and final evidence; source/archive/deployed manager SHA256 match |

Final follow-up reran `make check`, `./tests/run.sh --all` (38 lifecycle checks
and 4 real traffic checks), and `make openwrt-smoke` successfully. See
[evidence](evidence/2026-10-09-final-regressions.json). The runtime candidate is
unchanged at SHA256
`aadccde49bb7a788ee215dcd0e6777865f138a31c7bb56c1bb8cbf9c2a4ea720`.

The lifecycle fixture checks include malformed config, versioned schema,
credential handling without evaluation, private directories, reserved names,
configured listener conflicts, no-curl local-binary operation, hexdump fallback,
all four tunnel command forms, temporary/persistent lifecycle choices,
affected-only apply, repeated snapshot publication/collection, crash/orphan
recovery, stale PID protection, last-applied configuration after RAM loss,
RAM binary restoration, destructive update failure, actual scheduled retry after
simulated WAN restoration, HTTPS downgrade rejection, invalid ELF rejection,
persistent binary storage, no-rollback behavior, uninstall/purge, pseudo-terminal
menu/hidden-input/removal checks, and startup adapter/installer generation.

Startup lifecycle tests use **shims**, not real procd/systemd service ownership.
The OpenWrt rootfs additionally exercises actual rc.common enable/disable and
boot links, proving doctor does not acquire/create the procd lock while querying
registration. It does not boot procd or qualify real service supervision.
The OpenWrt rootfs lacks `od` and `stty`; the manager uses `hexdump` instead, and
secret-input menus can use a private password file. Downloads remain an optional
curl/CA capability. The rootfs smoke does not test downloads or native MIPS ABI.

Real traffic tests create their own TLS CA and server certificates and run a
separate test server; server mode is not a wtctl feature. Lifecycle tests do not
prove upstream behavior; the traffic smoke supplements them but is still a
container test. Container/emulated x86_64 success says nothing about MIPS float
ABI, actual RAM usage or performance on constrained hardware.

## Installer/autostart and doctor follow-up

The new installer prompt and boot diagnostics were tested locally after the
recorded physical campaign. `make check`, `./tests/run.sh --all` (38 grouped
lifecycle checks and 4 real traffic checks), and `make openwrt-smoke` passed.
Evidence/candidate hash: [boot integration local results](evidence/boot-integration-local.json).

The final lifecycle group now includes a real-PTY installer test for default-No,
explicit consent, re-enabling an existing disabled adapter without rewriting it,
and declining without changing an existing enabled preference. Unattended
`--startup`, `--no-startup`, repeated installation and invalid-option rejection
are covered. Doctor tests cover absent/enabled/disabled/masked/unknown/unmanaged
registration, read-only/non-root OpenWrt inspection, inaccessible registration
directories, unavailable query tools, and SysV start links. The real OpenWrt
rootfs exercises installer opt-in and disabled/re-enabled registration with
actual rc.common, without invoking a booted procd service.

The physical reports below apply to the earlier recorded runtime SHA256; these
installer/doctor additions have **not** been deployed or requalified on the
physical device. Historical physical evidence is unchanged.

## Owner-approved physical testing

The old installation was removed from the GL-AR300M, and wtctl was installed and
tested natively. **29 physical checks passed and 1 reverse-UDP check failed**;
4 separate active-download/final-setup checks passed. The shutdown/TERM race
found on hardware was fixed and locked down with a failing-then-passing local
regression. Exact configuration restoration and clean fixture removal succeeded
on the complete run. The final device has boot-enabled wtctl, RAM storage and no
tunnels configured; vendor/core configuration is unchanged.

This is **partial acceptance**, not production qualification. Reverse UDP lost a
datagram mid-stream in one complete-run check; earlier runs also timed out.
Focused restarts did not reproduce it. One controlled software reboot passed
boot recovery and all four traffic forms (13 recorded checks). Its original
driver result remains failed because an archive-byte cleanup assertion rejected
changed directory mtimes; independent exact configuration-content/permissions
and vendor-baseline verification completed restoration. The helper assertion is
fixed and locally tested; that standalone helper was not separately rerun.

The subsequent onsite suite passed **29 grouped checks** with no cleanup errors:
owner-operated physical power-cycle, true Wi-Fi WAN outage during operation and
at boot with missing RAM binary and unattended recovery, 30-minute concurrent
TCP load (about 800 MiB, zero client restarts), and simulated printer-like TCP
bursts/idle/reconnects. Aggregate owned CPU averaged 72.31%; minimum available
RAM was 57,964 KiB. Four clients were configured but only the two TCP clients
were continuously loaded. All four traffic forms passed after each recovery.
Three managed and three directly launched reverse-UDP trials also passed;
this did not reproduce or explain the historical failure and adds no claimed
runtime fix. Exact configuration restoration used the corrected comparison;
authentication, vendor hashes/packages/panel and removal of all test fixtures
were verified. The wtctl runtime is unchanged.

The requested simulated stream replaces real-printer testing for this task;
actual production LAN/printer behavior is not claimed. The bounded workload
results are not arbitrary-capacity or indefinite-operation qualification.
See [physical report and sanitized evidence](PHYSICAL-TESTS.md).

## Required physical OpenWrt acceptance before publication

Use exact candidate release assets on the intended firmware/device, with an
administrator-approved raw executable and a controlled peer. Preserve vendor
firmware/feeds, network/firewall settings and unrelated processes.

- [ ] Inventory actual applets, curl TLS/CA support, clock, CPU/endianness/ISA/ABI.
- [x] Measure 30-minute concurrent forward/reverse TCP CPU/RAM and verify
      payload integrity/no client restarts with four configured clients.
- [ ] Quantify flash configuration footprint, RAM download peak and qualify
      additional concurrency/traffic loads for a specific production deployment.
- [ ] Test local executable use without curl and chosen RAM/persistent strategy.
- [ ] Exercise CLI and menu including auth, custom CA, edits, apply and removal.
- [x] Verify all four traffic forms against controlled sinks after recovery;
      simulate printer-like reverse TCP bursts, idle and reconnects.
- [ ] Resolve intermittent reverse-UDP loss; actual target-device qualification
      is outside the owner's simulated-printer scope.
- [ ] Verify disabled tunnels remain stopped; temporary stops reset only as documented.
- [ ] Verify procd ownership, manager crash/respawn, tunnel crash recovery,
      and stop during an active download; no owned orphan survives.
- [x] Test controlled software reboot; restore last-applied settings without
      activating unapplied drafts; RAM executable re-download.
- [x] Test owner-operated physical power-cycle and equivalent recovery.
- [x] Test true WAN loss at boot and during operation, sustainable retries,
      and unattended recovery on WAN restoration.
- [ ] Test destructive update, unavailable URL, incompatible build and low space;
      accept deliberate no-rollback downtime.
- [ ] Verify unrelated wstunnel processes and services remain untouched.
- [ ] Verify uninstall, disabled startup registration and optional explicit purge.

## Known limits / residual risks

- User-selected downloads execute as root, with no checksum/authenticity proof.
- Minimal ELF identity/client-help checks cannot prove ISA/ABI/kernel compatibility.
- Secrets are plaintext to root and can appear in privileged client argv.
- No logs and no traffic-health status: failures expose an exit code, not a full reason.
- Listener checks cover configured collisions, not complete live socket reservations.
- Retry timing uses wall-clock epoch values and approximate polling deadlines.
- POSIX shell supervision forks baseline utilities; hardware resource measurements
  are an acceptance gate, not an assumed negligible overhead.
- Large tunnel counts can lengthen sequential shutdown beyond adapter timeouts;
  qualify the actual deployment load rather than claiming an unlimited capacity.
- Atomic rename prevents partial configuration visibility, not filesystem/power-loss
  durability guarantees. Reboot/power-cycle recovery passed for flushed settings;
  power loss specifically during a configuration write was not tested.
- systemd/SysV portability is implemented but real distro service integration is
  not qualified by generation tests.

## Release procedure

1. Run syntax/static, fixture, real-traffic and OpenWrt-userland checks.
2. Build `dist/wtctl-0.1.0.tar.gz` with `make dist`.
3. Complete physical gates against that exact archive on the intended device.
4. Record firmware/device, executable provenance/version, resource measurements,
   traffic and recovery evidence. Only then label the release OpenWrt-qualified.
5. Add qualification for other distros/devices only after equivalent real testing.

There is no automatic publishing or CI requirement. Current assets are development
artifacts, not an approved production deployment.
