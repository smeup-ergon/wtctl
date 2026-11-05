# wtctl

A small, root-operated **POSIX-shell wstunnel client manager** for Linux.
One complete INI configuration describes the device: software sources, servers,
tunnels and an optional remote control tunnel. It is applied locally with
`wtctl apply` or remotely with plain netcat. No LuCI, UCI, rpcd, Bash, Python,
jq or dialog is required at runtime.

**0.3.0 is a development release.** INI management has not been qualified on
physical hardware. Earlier GL-AR300M evidence describes 0.1.0, not this release.
See [validation](docs/VALIDATION.md) and [historical physical evidence](docs/PHYSICAL-TESTS.md).

## Install

Run as root (inspect and trust the source before running downloaded code):

```sh
curl -fsSL https://raw.githubusercontent.com/smeup-ergon/wtctl/main/scripts/install.sh | sh
```

Or run `sh scripts/install.sh` from a copied release, which installs the adjacent
`wtctl`. The installer takes no parameters and asks no questions. It:

1. refuses to run if `/usr/sbin/wtctl` already exists;
2. detects OpenWrt (procd), running systemd, or SysV with `update-rc.d`, and
   otherwise stops before changing anything;
3. installs `/usr/sbin/wtctl` (fetched from `main` with verified HTTPS-only
   redirects, size/time limits and syntax checks when streamed);
4. writes the sample `/etc/wtctl/wtctl.ini` unless that file already exists;
5. registers boot startup and starts an idle service with no tunnels and
   control disabled.

Curl with HTTPS and CA trust must already be installed. Then edit the sample and
apply it:

```sh
vi /etc/wtctl/wtctl.ini
wtctl validate /etc/wtctl/wtctl.ini
wtctl apply /etc/wtctl/wtctl.ini
```

The sample contains `REPLACE-ME` placeholders that validation rejects, so an
unedited sample cannot be applied. Its `url=` is the manager URL the installer
used, which is already accepted: keeping it downloads no new manager.

## Configuration

```ini
[wtctl]
format=1
url=https://raw.githubusercontent.com/smeup-ergon/wtctl/main/wtctl
wstunnel_url=https://downloads.example.com/wstunnel-mips-musl
storage=ram

[control]
enabled=true
server=office
bind=::
listen=8099

[server office]
endpoint=wss://tunnel.example.com
auth=path
prefix=YOUR_PREFIX

[tunnel printer]
server=office
direction=reverse
protocol=tcp
bind=127.0.0.1
listen=9100
target=192.168.1.50
port=9100
```

Every apply submits the **complete** configuration; the latest valid submission
wins. Omitting a tunnel removes it. Only affected tunnels restart. The full schema
and semantics are in [CONTROL-CONFIG-DESIGN.md](docs/CONTROL-CONFIG-DESIGN.md).

- `url=` / `wstunnel_url=`: HTTPS sources for wtctl and a raw native wstunnel
  executable (not an archive). **A changed URL requests an update**; unchanged
  URLs never re-download. There is no separate update command.
- `storage=ram` re-downloads the accepted binary after reboot; `persistent`
  keeps it in `/etc/wtctl/bin`.
- `[server NAME]`: `auth=none|path|basic` (with `prefix=` or `username=` and
  `password=`), optional `ca=` file for a private CA.
- `[tunnel NAME]`: for reverse tunnels the listener is on the server and the
  target is reached from this device; forward tunnels are the opposite.
  IPv6 uses `bind=::1` and `target=[::1]`.

Passwords are plaintext in root-only configuration and can appear in privileged
client arguments. Status output redacts credentials.

A download, validation or startup failure keeps the previous working setup,
reports `KO REASON`, and leaves the failed draft as desired configuration
without retrying it, including after reboot. Resubmit to retry.

## Remote control

With `[control] enabled=true` the device keeps a reverse tunnel to the server,
and configuration is read or replaced with plain netcat through the server's
forwarded port:

```sh
printf 'GET ACTIVE\n' | nc -w 5 SERVER 8099
{ printf 'PUT %s\n' "$(wc -c < device.ini | tr -d ' ')"; cat device.ini; } | nc -w 240 SERVER 8099
```

Enabling control, changing control connectivity or changing a software URL while
control is enabled returns `PENDING confirmation-required`: send the identical
bytes again through the new control path within 60 seconds to confirm it.
**There is no application authentication: restrict the server-side port with a
firewall.** See [Netcat control](docs/NETCAT-CONTROL.md).

## Commands

```text
wtctl status                  supervisor, binary, tunnel and control state
wtctl doctor                  platform, utilities, nc receiver and boot checks
wtctl validate FILE           offline validation; changes nothing
wtctl apply FILE|-            activate a complete configuration (- reads stdin)
wtctl uninstall [--purge] --yes
```

`daemon` and `shutdown` are service plumbing. For maintenance stop the owning
service (`/etc/init.d/wtctl stop` or `systemctl stop wtctl`).

## Requirements and recovery

Linux, mounted `/proc`, root, POSIX `sh`, and basic utilities (normally BusyBox):
`awk grep tr id ls chmod mkdir rm mv cp dirname basename date sleep head cmp dd
wc df uname cut`, plus `od` or `hexdump`. Downloads need **curl with HTTPS and
CA trust**; the control receiver needs BusyBox `nc` with `-lk -s -p -e`.
`wtctl doctor` reports these and never installs dependencies.

Binary checks compare ELF class/endianness/machine with `/bin/sh` and run a
bounded client-help check. They do **not** prove authenticity, complete ABI/ISA
compatibility or connectivity. Administrator-selected code executes as root.

Downloads require space for the retained old binary plus a candidate of up to
24 MiB and 1 MiB reserve (`max_kib=` / `reserve_kib=`). Missing RAM binaries are
recovered from the accepted URL with bounded exponential backoff. RAM mode needs
working networking, CA trust and a correct TLS clock.

`wtctl status` reports supervisor and binary phase, child PID, exit, restart
count and retry time, plus each tunnel's `listen=` and `target=` endpoints. These
are configured values, not verified sockets or traffic health.

## Uninstall

```sh
wtctl uninstall --yes          # removes boot integration; keeps /etc/wtctl
wtctl uninstall --purge --yes  # also deletes configuration and credentials
```

Startup files not created by wtctl are reported and left untouched. Reinstalling
after an uninstall without `--purge` keeps the configuration and accepted setup.
Installations from before 0.3.0 that used `server`/`tunnel` commands cannot be
migrated: uninstall them with `--purge` and reinstall.

## Development

```sh
make check          # syntax, ShellCheck, Python helpers
make test           # BusyBox lifecycle, downloads, control streams, installer
make integration    # real wstunnel v11, verified TLS, forward/reverse TCP/UDP
make compose-test   # multi-container acceptance lab with netcat control
make openwrt-smoke  # OpenWrt userland/adapter registration, not a boot test
make dist           # portable release in dist/
```

The 0.1.0 physical harnesses are version-gated historical tools. See
[design](docs/DESIGN.md), [operations](docs/OPERATIONS.md) and
[Compose acceptance](docs/COMPOSE-ACCEPTANCE.md).
