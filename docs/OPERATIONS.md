# Installation and operation

## OpenWrt-first deployment

1. Do not flash firmware, replace vendor feeds, or remove packages to make space.
2. Copy the portable release to the router over an existing authenticated admin
   channel. Run `sh scripts/install.sh --yes` as root. On a terminal, the installer
   offers boot autostart (default No). Accepting installs/enables the detected
   adapter without starting the service now; declining preserves existing boot
   preferences. Without a terminal it makes no boot changes unless you explicitly
   pass `--startup openwrt` (or `systemd`/`sysv`). Use `--no-startup` to suppress
   the prompt and leave registration unchanged.
3. Run `wtctl doctor`. Local-binary use needs only the documented shell/applet
   baseline and `/proc`. Downloads need curl HTTPS and CA trust; any package
   installation remains an explicit administrator decision.
4. Choose a tested raw wstunnel build for the device's architecture, endianness,
   ISA and ABI. The earlier project tested v11.0.0 on GL-AR300M MIPS32r2 musl
   soft-float; that **does not qualify this new manager**.
5. Run `wtctl` for guided setup or use the README's command sequence. Choose
   RAM storage when flash cannot accommodate the binary and reserve. Default
   download allowance is 24 MiB plus 1 MiB; reduce `max_kib` manually only if
   the chosen raw binary is known to fit. There is no automatic storage choice.
6. `wtctl apply`, then `wtctl daemon --background`. Verify real traffic from
   both ends; process status alone is insufficient.
7. If you skipped installer autostart, `wtctl startup enable openwrt --yes`
   installs procd startup at priority 99 or re-enables the existing managed
   adapter without rewriting it. It enables future boot startup but does not
   start the service now. `wtctl doctor` verifies the registration links. After
   stopping a manually launched supervisor with `wtctl shutdown`, run
   `/etc/init.d/wtctl start` to let procd own it. Do not leave two supervisors
   competing for ownership.
8. Verify recovery after reboot, WAN loss and subsequent WAN restoration before
   treating the release as operationally accepted.

The portable manager never invokes UCI/ubus. The OpenWrt boot adapter naturally
requires OpenWrt's existing rc.common/procd, not additional manager runtime
packages. Installing it on a non-OpenWrt distro is rejected.

## Other init systems

- `wtctl startup enable systemd --yes`; subsequently stop any manually launched
  supervisor and `systemctl start wtctl`. systemd restarts the manager and
  controls its process group.
- `wtctl startup enable sysv --yes` creates or re-enables `/etc/init.d/wtctl`. It registers
  with `update-rc.d` where available; otherwise register the start/stop hook
  using the distribution's documented boot mechanism. Start calls
  `wtctl daemon --background`, preserving disabled tunnel preferences.
- Unsupported init: launch `/usr/sbin/wtctl daemon` in your init system's
  foreground-service mechanism. Do not use `start all` as a boot command:
  it explicitly starts disabled tunnels too.

Adapters never overwrite an existing startup file. Remove only files bearing
the manager marker. They support the default executable/config/runtime paths.

## Current physical test status

The owner-approved GL-AR300M test device now runs wtctl with RAM storage and
procd startup enabled, with no tunnel profiles. Native control/TCP/download
checks, software reboot, owner-operated physical power-cycle and true WAN
recovery at boot/during operation passed. A 30-minute concurrent TCP load and
simulated printer-like stream also passed. Intermittent reverse-UDP loss remains
unresolved; matched managed/direct trials passed without isolating its cause.
Real printer behavior and arbitrary capacity are not qualified. See
[physical evidence](PHYSICAL-TESTS.md).

When procd/systemd owns the supervisor, use its service stop command to prevent
respawn. Direct `wtctl shutdown` stops the process but does not disable an init
watchdog; it is safe to repeat while that process is already terminating.

## Troubleshooting without tunnel logs

- `wtctl doctor`: utilities, platform, optional downloader/secret-input tools and
  boot registration. It inspects marked OpenWrt/SysV files and registration links
  without executing init scripts. systemd uses read-only `systemctl is-enabled`.
  Missing tools/permissions are reported as unknown; unmanaged paths are not
  executed. SysV start-link discovery does not establish the default runlevel,
  and arbitrary manually configured boot hooks cannot be reliably detected.
  Boot registration is not the supervisor's current running state.
- `wtctl status`: supervisor, binary phase, child state, last exit, restart count,
  epoch retry time. `date -d @EPOCH` is optional and not required by the manager.
- `download-failed`: check WAN, DNS, HTTPS URL, device clock, CA trust and storage.
- `incompatible-binary`: use a raw native executable with the required v11 client
  options; class/machine checks cannot prove float ABI/ISA compatibility.
- `insufficient-space`: choose RAM or adjust a known-safe budget; do not bypass
  firmware/vendor safeguards.
- Process backoff: check profile settings, listener conflicts, remote server
  authorization and real traffic. A living process can still be disconnected.
- `stop all` cancels binary retries. `start NAME` resumes wanted operation.
- Saved changes do nothing until `apply`. A new supervisor restores enabled
  tunnels only, not previous temporary starts/stops.

No automatic firewall or remote-server authorization changes are made. A
reverse non-loopback bind can expose a remote service; secure the server yourself.

## Update and uninstall

`binary configure ...` saves settings; apply them explicitly. Existing binaries
are reused until `binary update --yes` deletes them. That operation can cause
indefinite downtime if the source is unavailable; no rollback exists. It can
also execute arbitrary administrator-selected code as root during validation.

`wtctl startup remove ADAPTER --yes` stops/disables and removes the managed
startup adapter. For manually registered SysV hooks, also remove that external
registration yourself. Then `wtctl uninstall --yes` stops the manager, removes
runtime state and removes `/usr/sbin/wtctl` when invoked there. Configuration
and persistent managed binaries remain. Use `--purge --yes` only for intentional
deletion of `/etc/wtctl`. Externally supplied binaries are never deleted.
