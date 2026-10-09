# Physical device tests — 2026-10-09

## Target and safety

Owner-approved GL.iNet GL-AR300M (NOR), OpenWrt 22.03.4
`r20123-38ccc47687`, ath79/nand, MIPS, Linux 5.10.176. Native executable:
wstunnel-cli 11.0.0, 12,889,164 bytes, MIPS32r2 musl soft-float build already
selected by the previous project. The final manager script SHA256 is
`aadccde49bb7a788ee215dcd0e6777865f138a31c7bb56c1bb8cbf9c2a4ea720`.

SSH authentication was not written into source or evidence. Private configuration
backups were kept outside the repository. No firmware/feed, saved network/Wi-Fi,
firewall, system, nginx or unrelated package changes were made. SSH uses the
WAN-facing Wi-Fi interface. It was left enabled during the original suite;
onsite-authorized follow-up tests temporarily disabled it with verified timed
restoration and an operator available for recovery.

The old deployment had no server/tunnel profiles. Its two custom packages and
exactly 18 newly added LuCI/web dependencies were removed using the historical
`edge-net-devices/openwrt/docs/deployment-packages.json` inventory and dependency
checks, without force flags. Full before/after inventory comparison confirmed
exactly those 20 removals, no added packages and no other version changes.
The old manager, RPC/menu/ACL/UI files, loopback helper and port 8080 listener
were removed. Shared pre-existing vendor components and CA trust were retained.
A root-private configuration/package-inventory backup remains at
`/root/wtctl-legacy-backup` on the device.

## Results: partial acceptance, not a qualified production release

The complete physical suite recorded **29 passed checks and 1 failed check**.
Its initial wtctl configuration was restored exactly, cleanup errors were empty,
and its peer/probe/public CA/test profiles were removed. A separate final setup
and download-cancellation suite passed **4 checks**.

Evidence:

- [Complete physical suite](evidence/2026-10-09-device-tests.json) — `passed: false`
  intentionally, because of the reverse-UDP failure.
- [Active-download cancellation/final setup](evidence/2026-10-09-download-cancellation.json).
- [Three single-client restart cycles](evidence/2026-10-09-single-client-restarts.json).
- [Three four-client restart cycles](evidence/2026-10-09-four-client-restarts.json).
- [40-second downtime/restart diagnostic](evidence/2026-10-09-idle-restart.json).

Passed checks include:

- Actual POSIX/BusyBox utilities, native ELF/CLI compatibility, local-binary operation.
- Four clients managed by the portable supervisor under real procd ownership.
- Verified WSS/path authentication/custom CA and initial forward/reverse TCP/UDP
  payload integrity. TCP probes echoed 4 MiB; UDP probes exchanged 16 datagrams.
- Explicit apply, affected-only restart, temporary stop/start, persistent enable/disable.
- Child crash recovery, real procd supervisor SIGKILL/respawn and fresh-client reconciliation.
- Peer reconnect; untrusted CA blocked payloads and restoring trust restored TCP traffic.
- Actual SSH pseudo-terminal menu and redacted status.
- Real HTTPS download/validation/activation into RAM; too-small persistent storage
  safely rejected without a partial executable on flash.
- Destructive binary removal on update failure, scheduled recovery, stop cancelling
  retry, and restored TCP/UDP traffic after subsequent RAM recovery.
- Physical uninstall/reinstall preserving configuration and the externally supplied
  executable, followed by exact baseline restoration.
- Cancellation of an observed live curl download removed its partial data and
  cancelled retries; explicit install worked with no enabled tunnels.
- Vendor panel returned HTTP 200 locally. Network/firewall/system/nginx hashes
  and the post-removal package inventory remained unchanged through testing.

### Shutdown race found and fixed

`procd stop` may return while the supervisor is already handling TERM. A second
`wtctl shutdown` previously queued a request the terminating supervisor could not
consume, then reported failure when it exited. The fix accepts observed owned
supervisor exit as successful shutdown and removes the unconsumed request, so
it cannot kill the next supervisor. `tests/shutdown-race.sh` reproduced the
failure locally before the fix and passed after it. Native cleanup then passed.

Some earlier driver failures were also readiness checks that accepted old PIDs
before asynchronous apply/restart completed. The driver now waits for replaced
client PIDs and never treats process-running as verified traffic health.

### Reverse UDP remains an open failure

The complete run timed out **mid-stream after 8 of 16 datagrams reached the
peer's echo destination** following binary reactivation. All client processes
were still running without restarts. Later reverse-UDP recovery passed all 16.
Earlier broader runs also saw reverse-UDP timeouts. Single/four-client restart
and 40-second downtime diagnostics did not reproduce the failure.

The legacy and downloaded binaries were confirmed byte-identical as a diagnostic
check; this does not add a runtime checksum policy. The mid-stream observation
rules out merely testing before any connection was established, but does **not**
isolate whether the loss is in wstunnel, the test peer, or the Wi-Fi/network path.
It is not fixed, silently retried into a pass, or classified as a manager crash.
The driver records UDP failures while continuing independent checks, and exits
nonzero if any occurred. Actual production/printer behavior is not qualified;
the subsequently requested simulated printer-like stream passed below.

The bounded onsite comparison used the same native binary, client flags, custom
CA environment, path authentication, reverse UDP listener and destination.
**Three managed and three directly launched wstunnel trials passed**, each with
16 payload-matched datagrams and 16 corresponding peer echoes. The direct
process was identity-tracked, stopped, and replaced by the managed client.
This did not reproduce or isolate the old failure; it is not evidence that it
was fixed or definitively upstream. No wtctl lifecycle fault was reproduced, so
no speculative runtime workaround was added. Historical failed evidence stays
failed; investigation is closed for this bounded task, with UDP data-plane
intermittency retained as an interoperability caveat.

### Controlled software reboot — completed in follow-up

One owner-approved software reboot was performed with a reachable controlled
Docker peer and fresh, known-host SSH key authentication verified before reboot.
The temporary recovery key was removed afterward; `/etc/dropbear/authorized_keys`
was originally absent and is absent again. Passwords were not used in files or
arguments. Persistent private baseline recovery material remains under
`/root/wtctl-reboot-recovery`; workstation recovery archives remain outside the
repository. No WAN/network/firewall settings were changed.

The reboot driver recorded **13 successful checks**:

- Forward/reverse TCP and UDP payloads passed once before and once after reboot;
  each TCP check echoed 4 MiB, each UDP check exchanged 16 datagrams.
- Boot ID changed from `36ee5971-c28b-47b4-8b2d-4b0b8051b96a` to
  `f35a7a0c-deae-495c-9764-7ed2d88dc96b`; fresh SSH reconnected in 159.74 seconds
  within the 10-minute limit.
- The RAM probe disappeared, the persistent public test CA survived, and procd
  automatically restored the native executable into RAM and four enabled clients
  within the additional five-minute recovery limit. No persistent binary existed.
- The disabled tunnel stayed stopped. Traffic used the last-applied listener
  despite an unapplied saved listener edit; a temporary stop reset at reboot.

The driver's final **archive-byte comparison failed**, so its original
[`passed: false` result](evidence/2026-10-09-software-reboot.json) is preserved.
Independent comparison proved configuration paths, contents, types, ownership and
permissions identical: only directory mtimes changed during BusyBox tar
extraction. This was a helper assertion defect, not failed runtime recovery.
The helper now compares meaningful configuration entries; four local regressions
accept changed directory mtimes but reject changed content, permissions or extra
files. The corrected helper was not rerun through another physical reboot.

[Independent restoration evidence](evidence/2026-10-09-reboot-restoration.json)
records the completed cleanup: exact empty configuration, enabled startup and
idle supervisor, native RAM binary ready, no test CA/probe/profiles/tunnels/peer,
unchanged core hashes and package inventory, and local vendor panel HTTP 200.
Passing UDP here does **not** resolve or supersede the earlier intermittent loss.

### Onsite power-cycle, WAN loss, sustained load and simulated printer stream

The owner physically disconnected router power for the requested 10-second
interval and reconnected it. The new phased suite recorded **29 successful
grouped checks**, no failed checks, no cleanup errors, and verified baseline
restoration: [sanitized evidence](evidence/2026-10-09-onsite-tests.json).
This is a separate bounded passing run, not replacement of the original failure.

- **Physical power-cycle:** boot ID changed from
  `f35a7a0c-deae-495c-9764-7ed2d88dc96b` to
  `25f4e614-3f72-473b-bf70-6e61a4f81b21`; the RAM probe disappeared, procd
  recovered the RAM binary and enabled clients, the disabled control stayed
  stopped, and all four payload forms passed before and after.
- **True WAN loss during operation:** `/sbin/ifdown wwan` removed `wlan-sta0`
  connectivity for **136 seconds**, including SSH. A deliberately destructive
  test update removed the binary; the offline snapshot showed interface down,
  binary absent and scheduled retry. An SSH-independent restore process brought
  WAN back; unattended client recovery completed **292.11 seconds** after test
  start. All four traffic forms then passed.
- **WAN absent at boot:** a temporary marked START=98 fixture held WAN down
  before wtctl START=99. A controlled software reboot changed the boot ID to
  `bf05aac4-f57e-4b07-975b-306a8bc095f5`. Offline snapshots proved binary absent,
  interface down and supervisor alive/retrying. The timed restore brought WAN
  back after **187 seconds**; unattended recovery completed **273.79 seconds**
  after test start, followed by all four payload checks. Hook and boot symlink
  were removed. Saved network/Wi-Fi settings were never modified.
- **30-minute concurrent TCP load:** forward echoed **419,430,400 bytes** across
  100 verified connections; reverse echoed **419,678,232 bytes** across 6,403
  rounds on a continuously established stream. There were **zero client
  restarts** and no payload mismatches. Four clients were configured, with two
  TCP clients active and the two UDP clients idle. Across 51 samples, aggregate
  owned-process CPU (including wstunnel, not just the manager) averaged **72.31%**
  and peaked at **75.02%**. Summed RSS was **43,416–44,024 KiB** (shared pages
  double-counted); available RAM never fell below **57,964 KiB** and finished
  at 58,512 KiB. This qualifies only this bounded workload, not arbitrary tunnel
  counts, UDP throughput, or indefinite operation.
- **Simulated printer-like reverse TCP:** three connections echoed **4,141,533
  bytes**, using 1-byte through 1-MiB bursts, two 10-second idle periods per
  connection, and close/reopen cycles. The controlled echo sink was on the
  workstation; no real printer or production LAN endpoint was exercised.
- **UDP comparison:** three managed and three direct trials passed as detailed
  above. Two additional helper regressions prove failed managed/direct probes
  remain in evidence and make the phased CLI exit nonzero; clean trials do not
  claim historical resolution.

Configuration paths/content/types/ownership/permissions were restored exactly
using the corrected archive-entry comparison. Core hashes, package inventory,
local vendor HTTP 200, procd ownership, enabled boot registration and native
binary readiness were verified. Test CA/profiles/tunnels/probe/peer/direct client,
boot hook and temporary SSH authorization were removed. Root-private recovery
material is retained under `/root/wtctl-onsite-recovery`, separate from earlier
baseline backups; workstation private archives are outside the repository.
The installed wtctl runtime candidate did not change.

### Earlier short resource sample

With four tunnels, 20-second samples measured approximately **9.8–10.3% aggregate
CPU** and **42.4 MiB summed RSS** (shared pages double-counted). PSS was unavailable.
Available RAM was about 56 MiB with one binary copy and about 44 MiB while a second
legacy/managed copy existed. The temporary legacy copy was removed afterward.
This is not a sustained-load benchmark or an unlimited tunnel-count guarantee.

## Final device state

- `/usr/sbin/wtctl` installed; root-private `/etc/wtctl` configuration.
- OpenWrt startup registration enabled; procd-owned supervisor running.
- Explicit RAM storage, previous administrator-selected HTTPS binary URL, native
  v11 executable ready in `/tmp/wtctl/bin/wstunnel`.
- **No profiles or tunnels configured**, no test CA, peer or probe remaining.
- Temporary legacy binary and release staging removed. Old project packages absent.
- Overlay free: **1,508 KiB**, compared with 956 KiB before removal; a small
  root-private reboot recovery archive is retained.
- `/tmp` free: 47,560 KiB; available RAM: 61,612 KiB in the final onsite idle sample.
- Vendor HTTP panel works locally; core configuration unchanged.

## Still required

Software reboot, owner-operated physical power-cycle, true WAN loss both during
operation and at boot, 30-minute concurrent TCP load, and the owner-requested
simulated printer stream are complete. The historical intermittent reverse-UDP
failure is still unresolved; no upstream cause or runtime fix is claimed.
Actual printer/production LAN behavior is outside the agreed simulated-stream
scope. Arbitrary capacity, long-duration UDP load and other firmware/distro
qualification are not established. These limits prevent a blanket production
qualification claim.

## Reproduce safely

Only on an owner-approved empty/disposable deployment, with a verified SSH host
key and an already authenticated control socket. The test refuses existing
profiles/tunnels/startup integration and preserves a private recovery archive on
restoration failure. Stop and investigate failures; do not overwrite production
settings to satisfy preflight. Before rerunning against the final device, explicitly
remove its wtctl startup adapter and restore an empty local-binary test baseline.

```sh
./tests/build-device-probe.sh
make integration                 # builds the pinned real-wstunnel test image
# Build a restricted LAN peer; only controlled echo destinations are allowed.
docker build --platform linux/amd64 -f tests/Dockerfile.device-peer \
  -t wtctl-device-peer:local .
python3 tests/device-test.py --target root@DEVICE --control-socket "$CONTROL" \
  --host-ip WORKSTATION_LAN_IPV4 --probe dist/test-tools/net-probe \
  --binary-url-file /private/approved-binary-url \
  --output dist/acceptance/device-results.json
```

For a **separately approved software reboot** on the final empty, boot-enabled
RAM deployment, the narrow helper accepts a fresh authenticated recovery key
instead of the old control socket. Establish and test that key and preserve the
original authentication configuration before invoking it; restore authentication
separately afterward. It requires existing RAM binary readiness and unchanged
installed candidate, refuses existing profiles/tunnels/listeners, keeps private
configuration backups on the workstation and under `/root`, and leaves startup
enabled after restoring the empty baseline. Stop if recovery fails; do not retry
reboots or payload failures silently.

```sh
python3 tests/device-reboot-test.py --target root@DEVICE \
  --identity /private/temporary-recovery-key --host-ip WORKSTATION_LAN_IPV4 \
  --probe dist/test-tools/net-probe --output dist/acceptance/reboot.json --yes-reboot
```

The private URL file may contain a signed URL; never commit it. Authentication is
provided by the SSH session, never CLI password arguments. The fixture binds its
three published ports to the specified workstation LAN address; reverse listeners
remain container-loopback-only. The original `device-test.py` has no reboot/WAN
operations; the dedicated helpers are explicit opt-in tests.

The onsite phased helper needs an onsite operator, fresh tested recovery key,
empty boot-enabled RAM deployment and restricted peer image. Before `prepare`,
create root-private `/root/wtctl-onsite-recovery` and preserve original SSH
configuration there; key setup/removal is deliberately outside the test driver.
Keep `--private` outside the repository because its baseline contains the saved
administrator-selected URL. Each phase requires `--yes`; WAN phases interrupt
SSH, and `boot-wan` installs a temporary marked boot hook and requests reboot.
Do not run those phases unattended or without a verified recovery plan.

```sh
run_phase() {
  python3 tests/device-onsite-test.py "$1" --private /private/onsite-recovery \
    --identity /private/temporary-recovery-key --target root@DEVICE \
    --host-ip WORKSTATION_LAN_IPV4 --probe dist/test-tools/net-probe \
    --output dist/acceptance/onsite.json --yes
}
run_phase prepare
# Only after successful preflight: owner disconnects/reconnects router power.
run_phase power-check
run_phase load       # 1800 seconds, plus printer-like stream checks
run_phase udp        # three trials each, failures retained; no retries into pass
run_phase wan        # independent timed restore must pass preflight
run_phase boot-wan   # separately approved boot-time outage + software reboot
run_phase cleanup
# Restore original SSH authorization separately and verify no fixtures remain.
```

Stop after failures and restore the baseline; do not repeat physical events to
replace failed evidence. Retain private backups until restoration is verified.
