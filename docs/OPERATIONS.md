# Installation and operation (0.2.0)

## Deployment

1. Do not flash firmware, replace feeds or remove packages to make room.
2. Provision curl HTTPS and CA trust explicitly. Run `./wtctl doctor` to inspect
   the shell/applet baseline and mounted `/proc`; it never installs dependencies.
3. Select a trusted raw executable matching CPU, endianness, ISA and ABI/libc.
   A matching ELF header does not establish complete compatibility.
4. Copy the release directory through an authenticated administrator channel.
   Run `sh scripts/install.sh --yes` as root; numbered setup selects RAM or
   persistent storage and accepts the approved HTTPS raw-executable URL.
   Unattended equivalent:

   ```sh
   sh scripts/install.sh --yes --storage ram --url 'https://HOST/RAW_BINARY' --startup openwrt
   ```

5. Setup downloads/validates, enables boot startup and starts the service. It
   detects OpenWrt, running systemd or SysV with update-rc.d. Choose an adapter
   explicitly with --startup if needed. Unsupported automatic boot registration
   fails; no false claim of autostart. Default paths are required.
6. Run `wtctl` for server/tunnel management. All choices are keyed; text input
   is only for values. Every saved tunnel starts now and at boot, without apply
   or enable commands. Verify real traffic at both ends.
7. Validate actual reboot, WAN-loss recovery and storage limits on the approved
   device before operational acceptance. Correct TLS clock/CA trust is essential
   for RAM redownload at boot. No automatic firewall/authorization changes occur.

Non-loopback binds expose listeners. For reverse mode this exposure is on the
remote server; secure that server yourself. The default bind is loopback.

## Updating

Rerun the release's installation script. Omitted URL reuses the current source
and compatible executable; an explicit --url always downloads a candidate.
Storage selection preserves the current mode if omitted unattended. Existing
server/tunnel records remain intact. Candidate validation runs as root.

```sh
sh scripts/install.sh --yes --url 'https://HOST/NEW_RAW_BINARY'
```

Downloads leave working clients undisturbed. Activation briefly pauses them and
keeps a rollback executable until local startup is acknowledged. Failed download
or validation restores settings without deleting the working executable. Space
must accommodate both retained executable and bounded candidate plus reserve.
An interruption by SIGKILL/power loss is not a crash-atomic transaction guarantee.
Startup registration/service-start errors are reported; inspect doctor/status
rather than assuming successful setup from partial output.

## Maintenance and troubleshooting

- `wtctl doctor`: platform, utilities, download/secret capabilities and boot
  registration. Unmanaged paths are not executed; missing query tools or
  inaccessible data report unknown. Boot registration is not traffic health.
- `wtctl status`: supervisor/binary phase, child state/PID, last exit, restart
  count and retry epoch. Counters are per-worker lifetime, not persistent history.
- Missing RAM binaries retry while at least one tunnel exists. Downloads use
  verified HTTPS-only redirects and bounded exponential backoff indefinitely.
- `download-failed`: check WAN, DNS, source URL, clock, CA trust and space.
- `incompatible-binary`: use a raw native supported-client executable; class and
  machine checks do not prove ISA/ABI compatibility.
- Process backoff: check listener conflicts, server authorization and endpoint
  connectivity. Client failures retain the configuration and retry.
- Local worker-start or configuration validation failures roll back the edit.
  A running worker does not guarantee client socket binding or successful traffic.
- Editing a shared server automatically restarts all referencing tunnels;
  other tunnels remain running. In-use servers cannot be deleted.
- Remove a tunnel to stop it permanently. No disabled records or temporary stops.
- For global maintenance, stop the owning service (`/etc/init.d/wtctl stop` or
  `systemctl stop wtctl`), then start it again when ready. `wtctl shutdown` alone
  can be undone by an init watchdog. Concurrent shutdown is idempotent.

## Uninstall

```sh
wtctl startup remove openwrt --yes  # use the adapter installed by setup
wtctl uninstall --yes
```

This preserves configuration and persistent binary for reinstall. Instead use
`wtctl uninstall --purge --yes` only for intentional irreversible deletion of
manager configuration and credentials. Runtime state/RAM binary and the installed
manager are removed; packages/network/firewall and release directories are untouched.

## Physical evidence

[Existing physical reports](PHYSICAL-TESTS.md) describe the earlier 0.1.0 lifecycle.
The 0.2.0 simplification has not been tested on physical hardware. Historical
physical harnesses fail closed on a newer version rather than executing obsolete
disabled/draft/destructive-update scenarios. New device acceptance is still needed;
container/PTY and traffic checks do not substitute for reboot/power/WAN qualification.
