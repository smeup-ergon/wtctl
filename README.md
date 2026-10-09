# wtctl

A small, root-operated **POSIX-shell wstunnel client manager** for Linux.
Command-first, with a plain numbered terminal menu. No LuCI, UCI, rpcd, Bash,
Python, jq, dialog, or package-manager integration is required at runtime.

**Status: development version with bounded native OpenWrt validation.**
GL-AR300M lifecycle/download, software reboot, physical power-cycle, WAN recovery
at boot/during operation, 30-minute TCP load and simulated printer-stream tests
passed. An earlier intermittent reverse-UDP timeout remains unresolved despite
passing managed/direct comparison trials. Actual printer behavior and arbitrary
capacity are not qualified.
See the [physical report](docs/PHYSICAL-TESTS.md). Container success alone is not
hardware acceptance or a claim of cross-distro qualification.

## Features

- Server profiles: WSS, none/path-prefix/basic authentication, custom CA files.
- Independently enabled forward/reverse TCP/UDP tunnels.
- A portable supervisor, independent per-tunnel restart/backoff, optional boot adapters.
- Private persistent configuration, explicit apply, restart only affected tunnels.
- Explicit RAM/persistent binary storage, supplied HTTPS URL or local binary.
- Reboot recovery and indefinite, bounded download retries through WAN outages.
- Process status only; **no tunnel logs**, connectivity claims, or firewall changes.

## Requirements

Linux with mounted `/proc`, root, POSIX `sh`, and these basic utilities (normally
BusyBox applets): `awk grep tr id ls chmod mkdir rm mv cp dirname basename date
sleep head cmp dd wc df uname`, plus either `od` or `hexdump` for ELF checks.

Downloads additionally require **curl with HTTPS support and CA trust**. They are
optional: an existing compatible binary works without curl. We deliberately do
not rely on varying BusyBox wget TLS implementations. On OpenWrt, `wtctl doctor`
suggests `opkg install curl ca-bundle`; it never installs packages itself.
Hidden password entry additionally needs `stty`; when absent, the menu accepts
an existing one-line password file instead. There is no compiled manager
or architecture-specific wtctl build. The **wstunnel binary** must match the
CPU, endianness, ISA, ABI/libc and OS—not merely the SoC name.

## Install

Copy this directory/release to the device and run as root:

```sh
sh scripts/install.sh --yes
wtctl doctor
wtctl                 # interactive setup menu on a terminal
```

Installation puts the single script at `/usr/sbin/wtctl`. It does not register
startup, download binaries, modify firmware/feeds, or start tunnels. No build is
needed. You can also execute `./wtctl` directly as root for development.

### Command-first setup

```sh
wtctl init
wtctl server add office --endpoint wss://tunnel.example.com --auth path --prefix YOUR_PREFIX
wtctl tunnel add printer --server office --direction reverse --protocol tcp \
  --bind 127.0.0.1 --listen 9100 --target 192.168.1.50 --port 9100
wtctl enable printer

# URL must serve a RAW executable, not an archive. Supply your approved build.
wtctl binary configure ram 'https://downloads.example.com/wstunnel-mips-musl'
# Or: wtctl binary use /opt/wstunnel

wtctl apply
wtctl daemon --background
wtctl status
```

New tunnels are disabled by default. Non-loopback binds are supported without an
extra approval prompt; their exposure is the administrator's responsibility.
For reverse tunnels, the bind/listen address is on the **remote server** and the
target is reached from this device. For forward tunnels, the listener is local
and the target is reached from the server. IPv6 target literals use brackets;
bind literals do not: `--bind ::1 --target '[::1]'`.

For basic authentication, avoid putting passwords on command lines:

```sh
# Create a private one-line file securely, or use the hidden-input menu.
wtctl server edit office --auth basic --username USER --password-file /root/wstunnel.password
wtctl apply
```

Passwords remain plaintext in root-only configuration and may appear in
privileged wstunnel process arguments. CLI output redacts endpoints and secrets.

## Lifecycle

| Command | Behavior |
| --- | --- |
| `apply` | Validate/snapshot saved config; running supervisor reconciles it within about 5 seconds |
| `daemon` | Run supervisor in foreground; suitable for an init system |
| `daemon --background` | Launch supervisor and restore enabled tunnels only |
| `start [NAME\|all]` | Launch supervisor if necessary; explicitly start named/all applied tunnels, even disabled ones |
| `stop [NAME\|all]` | Temporarily stop named/all tunnels; `stop all` cancels downloads/retries too |
| `enable NAME\|all` / `disable NAME\|all` | Save startup preference; requires `apply` |
| `shutdown` | Stop supervisor, owned download tasks and owned tunnels; an active init watchdog may restart it |
| `status` | Supervisor/binary phase, child PID, last exit, restart count, retry epoch |

For an init-owned supervisor, stop its service (`/etc/init.d/wtctl stop` or
`systemctl stop wtctl`) to prevent the init watchdog restarting it. Concurrent
shutdown is idempotent even when init already sent TERM.

Configuration edits never take effect until `apply`, including after reboot:
the last applied snapshot is persistent. First launch creates an initial snapshot
if none exists. A temporary stop survives
ordinary applies. Changing enabled/disabled preference through apply clears that
tunnel's temporary override. Supervisor restart clears all temporary overrides
and restores enabled tunnels. Restart counters are per worker lifetime, not
persistent history. Tunnel output is discarded. `status` is **not** a traffic
health check.

### Downloads and destructive updates

```sh
wtctl binary install --yes
wtctl binary update --yes
```

Both are explicit destructive operations: **stop owned tunnels, remove the
selected managed binary, download/validate its replacement**. No rollback. A
failed update leaves tunnels down until recovery succeeds. Existing external
binaries are never updated or removed. Managed storage is space-checked first.

Downloads use verified HTTPS, HTTPS-only redirects, 20-second connection and
180-second transfer timeouts, and a size bound. Default capacity budget: 24 MiB
plus 1 MiB reserve. Downloads stage into a non-executable `.part` file, compare
ELF class/endianness/machine with `/bin/sh`, then execute a bounded client-help
compatibility check and rename the accepted candidate. These checks are **not
proof of full ABI compatibility or authenticity**. There are deliberately no
required checksums. Administrator-selected code executes as root during validation.

Failures retry indefinitely: approximately 30 seconds initially, exponential
backoff to approximately 5 minutes, with jitter. Supervisor polling can add a
few seconds. Automatic recovery happens while any tunnel is wanted; explicit
install/update also downloads without active tunnels. `stop all` cancels that
explicit recovery request. RAM mode needs a working network and trusted TLS
clock/CA setup after every reboot; persistent mode does not re-download an
existing compatible binary on startup.

## Boot integration

Choose explicitly after applying a working configuration:

```sh
wtctl startup install openwrt --yes
# Alternatives: systemd or sysv
```

Adapters require installation at `/usr/sbin/wtctl` and default config/state paths.
Installation enables future boot startup; it does not start the service now.
OpenWrt procd/systemd supervise only the portable manager, not each tunnel.
The SysV adapter registers with `update-rc.d` if available; otherwise it prints
that manual boot-hook registration is still required. Linux/BusyBox has no
universal boot hook. See [installation and operation](docs/OPERATIONS.md).

```sh
wtctl startup remove openwrt --yes
wtctl uninstall --yes           # preserve configuration and persistent binary
wtctl uninstall --purge --yes   # explicitly remove manager-owned configuration too
```

Remove startup integration before uninstalling. External binaries are never
removed.

## Development

```sh
make check          # syntax + ShellCheck (Docker)
make test           # BusyBox fixture lifecycle/download tests
make integration    # real wstunnel v11, verified TLS, forward/reverse TCP/UDP
make openwrt-smoke   # OpenWrt 22.03.4 container userland only
make dist           # portable source/script release in dist/
```

Development containers need Docker and download testing packages; those are not
device dependencies. Traffic tests download upstream v11.0.0 linux/amd64 into a
container only. `tests/run.sh --all` runs both suites. See
[design](docs/DESIGN.md) and [validation/release gates](docs/VALIDATION.md).
