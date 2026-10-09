# wtctl

A small, root-operated **POSIX-shell wstunnel client manager** for Linux.
One setup script, automatic tunnel lifecycle, and single-key menus. No LuCI,
UCI, rpcd, Bash, Python, jq or dialog is required at runtime.

**0.2.0 is a development release.** The simplified lifecycle has not been
requalified on physical hardware. Earlier GL-AR300M evidence describes 0.1.0,
not this release; an intermittent reverse-UDP timeout remains unresolved.
See [validation](docs/VALIDATION.md) and [historical physical evidence](docs/PHYSICAL-TESTS.md).

## Setup and updates

Copy the release directory to the device, then run as root:

```sh
sh scripts/install.sh --yes
wtctl
```

Setup asks for RAM/persistent storage and an approved **HTTPS URL serving a raw
native wstunnel executable**, not an archive. It downloads and validates the
binary, automatically enables boot startup, and starts the service now. RAM is
the default for unattended first setup. Existing settings and tunnels are
preserved on reruns; blank URL input keeps the current source and binary.

For unattended setup:

```sh
sh scripts/install.sh --yes --storage ram \
  --url 'https://downloads.example.com/wstunnel-mips-musl' --startup openwrt
```

OpenWrt and running systemd are detected automatically, as is SysV with
`update-rc.d`. Use `--startup systemd` or `--startup sysv` to select explicitly.
If detection fails, the interactive wizard offers numbered adapters; unattended
setup requires `--startup`. SysV without `update-rc.d` fails rather than falsely
claiming automatic boot registration. Startup integration requires default
paths and installation at `/usr/sbin/wtctl`.

**Update by rerunning the same script with `--url`:**

```sh
sh scripts/install.sh --yes --url 'https://downloads.example.com/new-wstunnel'
```

An explicitly supplied URL triggers replacement even if the URL is unchanged.
The candidate downloads and validates while existing tunnels keep running.
Activation briefly stops clients, retains the old binary until local startup is
acknowledged, and rolls back on failure. Failed downloads leave the old binary,
configuration and clients intact. Changing storage uses the same safe process.
No separate init, apply, binary configure/install/update, or enable/disable commands.

## Tunnels

Use `wtctl` for the menu, or use the CLI:

```sh
wtctl server add office --endpoint wss://tunnel.example.com --auth path --prefix YOUR_PREFIX
wtctl tunnel add printer --server office --direction reverse --protocol tcp \
  --bind 127.0.0.1 --listen 9100 --target 192.168.1.50 --port 9100
wtctl status
```

**Every saved tunnel starts immediately and automatically at boot.** Edits apply
implicitly, restarting only affected tunnels. Editing a shared server restarts
all its tunnels; the menu shows the affected names before saving. Invalid
configuration or inability to start the local worker restores the previous
record and snapshot. Remote outages/client failures retain the tunnel and retry.
Acknowledgment is **not a connectivity or socket-reservation guarantee**.

To stop a tunnel permanently:

```sh
wtctl tunnel remove printer
```

There are no disabled tunnels or temporary-stop states. A server referenced by
a tunnel cannot be removed. Removing a tunnel also stops its owned worker/client.

For reverse tunnels, bind/listen is on the remote server and the target is
reached from this device. For forward tunnels, the listener is local and the
target is reached from the server. Non-loopback exposure is your responsibility;
no firewall or server authorization changes are made. IPv6 targets use brackets,
e.g. `--bind ::1 --target '[::1]'`.

Basic authentication uses hidden menu entry or a private one-line password file:

```sh
wtctl server edit office --auth basic --username USER --password-file /root/wstunnel.password
```

Passwords are plaintext in root-only configuration and can appear in privileged
client process arguments. Status/listings redact credentials and endpoints.

## Menus

All choices, confirmations, and existing server/tunnel selections have keys.
Press `1`–`9` directly; longer lists continue with `a`–`z`. `0` is always
Back/Exit/Cancel. No Enter or pagination is needed for ordinary choices. URLs,
names, addresses, ports and credentials remain normal text entry with Enter.
Without usable `stty`, choices fall back to Enter-based input. Lists exceeding
35 entries use numbered line input rather than ambiguous multi-key shortcuts.
EOF and signals restore terminal settings. Editing uses a complete wizard;
CLI edits can change individual fields.

## Requirements and recovery

Linux, mounted `/proc`, root, POSIX `sh`, and basic utilities (normally BusyBox):
`awk grep tr id ls chmod mkdir rm mv cp dirname basename date sleep head cmp dd
wc df uname cut`, plus `od` or `hexdump`. Setup/download recovery needs **curl
with HTTPS and CA trust**. Existing managed binaries operate without curl.
`wtctl doctor` reports capabilities; it never installs dependencies.
Single-key navigation and hidden passwords need `stty`; without it, passwords
are supplied through an existing private file.

Binary checks compare ELF class/endianness/machine with `/bin/sh` and run a
bounded client-help check. They do **not** prove authenticity, complete ABI/ISA
compatibility or connectivity. Administrator-selected code executes as root.
No checksum/signature requirement is imposed.

Downloads require space for the retained old binary plus a candidate of up to
24 MiB and 1 MiB reserve. Verified HTTPS-only redirects, connection/transfer
limits and size bounds apply. Missing RAM binaries recover after reboot while
any tunnel exists; failures retry indefinitely with bounded exponential backoff
and jitter. RAM mode needs working networking, CA trust and a correct TLS clock.
Persistent mode reuses its existing compatible binary.

`wtctl status` reports supervisor/binary phase, child PID, exit, restart count
and retry epoch. No tunnel logs or traffic-health claims. `daemon` and
`shutdown` remain service plumbing, not tunnel controls. Stop the owning service
(`/etc/init.d/wtctl stop` or `systemctl stop wtctl`) for maintenance; an active
init watchdog can undo a direct shutdown.

## Uninstall

Remove the adapter used by setup, then uninstall as root:

```sh
wtctl startup remove openwrt --yes  # or systemd/sysv
wtctl uninstall --yes              # preserves configuration/persistent binary
# Instead, for irreversible deletion of manager configuration and credentials:
# wtctl uninstall --purge --yes
```

Packages, networking, firewall settings and release directories are untouched.
This fresh-install schema intentionally has no 0.1.0 migration.

## Development

```sh
make check          # syntax, ShellCheck, Python helpers
make test           # BusyBox lifecycle/download/setup and real PTY regressions
make integration    # real wstunnel v11, verified TLS, forward/reverse TCP/UDP
make openwrt-smoke   # OpenWrt userland/adapter registration, not a boot test
make dist           # portable release in dist/
```

Physical 0.1.0 harnesses are version-gated historical tools, not acceptance
coverage for 0.2.0. See [design](docs/DESIGN.md) and [operations](docs/OPERATIONS.md).
