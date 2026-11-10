# Installation and operation (0.3.0)

## Deployment

1. Do not flash firmware, replace feeds or remove packages to make room.
2. Provision curl HTTPS and CA trust explicitly. Run `wtctl doctor` (or
   `sh wtctl doctor` from a release) to inspect the shell/applet baseline,
   mounted `/proc` and the dropbear control receiver; it never installs dependencies.
3. Select a trusted raw executable matching CPU, endianness, ISA and ABI/libc.
   A matching ELF header does not establish complete compatibility.
4. As root, run the installer (trust/inspect the downloaded code first):

   ```sh
   curl -fsSL https://raw.githubusercontent.com/smeup-ergon/wtctl/main/scripts/install.sh | sh
   ```

   Or copy a release through an authenticated channel and run
   `sh scripts/install.sh`. The installer has no parameters or prompts. It
   detects OpenWrt, running systemd or SysV with `update-rc.d` and stops before
   changing anything if none is found. It refuses to run when
   `/usr/sbin/wtctl` exists.
5. The installer registers boot startup and starts an idle service: no tunnels
   and control disabled. It writes `/etc/wtctl/wtctl.ini` with `REPLACE-ME`
   placeholders unless that file already exists.
6. Edit the configuration, then `wtctl validate` and `wtctl apply` it. The
   first apply downloads wstunnel; the installed manager URL is already
   accepted, so keeping `url=` downloads no manager. Verify real traffic at both
   ends.
7. Validate actual reboot, WAN-loss recovery and storage limits on the approved
   device before operational acceptance. Correct TLS clock/CA trust is essential
   for RAM redownload at boot. No automatic firewall/authorization changes occur.

Non-loopback binds expose listeners. For reverse mode this exposure is on the
remote server; secure that server yourself. The default tunnel bind is loopback.
The control listener is exposed on the server without authentication:
**firewall it**. While control is enabled, the device has a blank-password,
root-equivalent `wtctl` account accepted only by the control receiver;
`KO control-unavailable` means dropbear is missing or another `wtctl` account
exists.

## Changing configuration and updating

Edit `/etc/wtctl/wtctl.ini` (or any file) and run `wtctl apply FILE`, or send a
`PUT` through the control tunnel with `ssh` ([CONTROL.md](CONTROL.md)). Both
use the same validation and activation path. Software updates are URL changes:
set a new `url=` or `wstunnel_url=` (a changed query string counts) and apply.

Downloads are staged and validated while working clients keep running.
Activation then replaces software and tunnels as a whole. A failure restores the
previous software, control settings and tunnels on a best-effort basis while the
activation process lives. Replacing the manager restarts the supervisor in place,
keeping its PID so procd/systemd continue to own the service. An interruption by
SIGKILL or power loss is not a crash-atomic transaction guarantee.

## Maintenance and troubleshooting

- `wtctl doctor`: platform, utilities, download and dropbear receiver capabilities,
  and boot registration. Unmanaged paths are not executed; missing query tools or
  inaccessible data report unknown. Boot registration is not traffic health.
- `wtctl status`: supervisor/binary phase, child state/PID, last exit, restart
  count and retry epoch, applied server, direction/protocol and
  `listen=<bind>:<port> target=<host>:<port>` endpoints (IPv6 bracketed), and a
  separate `Control:` line. Endpoints are configuration, not verified sockets.
- `/etc/wtctl/desired.ini` is the latest valid submission; `active.ini` is the
  last fully activated one. Boot uses the active configuration.
- `KO download-failed`: check WAN, DNS, source URL, clock, CA trust and space.
- `incompatible-binary`: use a raw native supported-client executable; class and
  machine checks do not prove ISA/ABI compatibility.
- Process backoff: check listener conflicts, server authorization and endpoint
  connectivity. Client failures retain the configuration and retry.
- For global maintenance, stop the owning service (`/etc/init.d/wtctl stop` or
  `systemctl stop wtctl`), then start it again when ready. `wtctl shutdown` alone
  can be undone by an init watchdog. Concurrent shutdown is idempotent.

## Uninstall

```sh
wtctl uninstall --yes
```

This stops and unregisters the managed boot adapter, stops all tunnels, and
removes runtime state and `/usr/sbin/wtctl`. Configuration and a persistent
binary are preserved for reinstall. Use `wtctl uninstall --purge --yes` only for
intentional irreversible deletion of configuration and credentials. Startup
files not created by wtctl are reported and left untouched; packages, network,
firewall and release directories are untouched.

Pre-0.3.0 record-based installations have no migration path, and a 0.3.0
manager reports them on every command except `shutdown`/`uninstall`. With the
old manager, run `wtctl startup remove ADAPTER --yes` and
`wtctl uninstall --purge --yes`, then run the 0.3.0 installer.

## Physical evidence

[Existing physical reports](PHYSICAL-TESTS.md) describe the earlier 0.1.0 lifecycle.
0.3.0 was exercised on a GL-AR300M on 2026-11-06, including one software
reboot ([results](CONTROL-QUALIFICATION.md#2026-11-06-physical-gl-ar300m)), and
on 2026-11-09/10 with power-cycle, WAN loss during operation and at boot, and
sustained load ([results](CONTROL-QUALIFICATION.md#2026-11-0910-power-cycle-wan-loss-and-sustained-load-on-gl-ar300m)).
At full CPU the GL-AR300M drops occasional UDP datagrams; size tunnel load to
the device. Keep the device clock correct (NTP): a clock behind the server
certificate's validity start makes TLS, and therefore confirmation, fail.
Historical physical harnesses fail closed on a newer version rather than
executing obsolete scenarios; container and traffic checks do not substitute
for reboot/power/WAN qualification on other devices.
