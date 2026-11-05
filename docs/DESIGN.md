# Design (0.3.0)

## Boundaries

One root-operated POSIX-shell executable; Linux `/proc` supplies process identity.
No UCI, ubus or rpcd dependency in the core. Installation uses the existing init
system for boot registration and service ownership. The manager never changes
firewall, network interfaces, firmware, feeds, packages or unrelated processes.
Help, version, doctor and validate remain non-root, read-only operations.

Management is configuration-driven only ([ADR 0001](adr/0001-shared-desired-config-and-activation-state.md),
[ADR 0003](adr/0003-remove-interactive-and-record-management.md)): one complete
INI desired configuration, applied locally (`wtctl apply`) or through the control
tunnel. There are no menus, prompts or per-record mutation commands.
[CONTROL-CONFIG-DESIGN.md](CONTROL-CONFIG-DESIGN.md) specifies the schema,
activation, candidate confirmation and protocol.

A foreground supervisor polls requests each second and normally reconciles every
five seconds. Activation requests force immediate reconciliation before
acknowledgment. One shell worker per configured tunnel owns a client. Rapid
client failures back off from 2 to 30 seconds; surviving 60 seconds resets
backoff. All client output is discarded with `RUST_LOG=off`; no tunnel logs are
stored.

## Data

Persistent `/etc/wtctl` and runtime `/tmp/wtctl` are root-owned mode 0700. Files
are private; executables are mode 0700. Symlink path components and overlapping
roots are rejected. `WTCTL_CONFIG_DIR`/`WTCTL_STATE_DIR` are development overrides,
not supported by the device installer/startup adapters. Ancestors must be trusted.

- `wtctl.ini`: the operator's file, written as a sample by the installer and
  never read implicitly.
- `desired.ini`, `active.ini`, `activation-state`: latest valid submission, last
  fully activated submission, and accepted software URLs.
- `global`, `control`, `servers/NAME`, `tunnels/NAME`: internal records compiled
  from the active INI. They are strict `key=value` data, never sourced or
  evaluated, and are not an editing interface.
- `applied/GENERATION`, `current`, `accepted-current`: immutable snapshots used
  by workers and rollback. Boot restores `accepted-current`.
- `bin/wstunnel`: managed persistent binary, when selected.

IDs use ASCII letters, digits, underscore/hyphen, max 64 characters; `all`,
`global`, `__control` and `__previous_control` are reserved. All configured
listeners are compared for conservative conflicts. Reverse conflicts are scoped
to the same profile. This is not an OS socket reservation. Worker acknowledgment
means local worker startup, not client parsing, socket binding or connectivity.

Activation protects ordinary command failures and caught signals, **not durable
crash-atomicity across SIGKILL or power loss**. Requalify abrupt power-loss
behavior before production acceptance.

## Ownership and recovery

PID files pair PID with `/proc/PID/stat` start time; zombies are considered exited.
Cleanup signals only recorded live owners. Supervisor recovery cleans owned
orphans, then restores every accepted tunnel. procd/systemd supervise the manager;
manual background launch and SysV have no equivalent watchdog.

Root-private atomically published requests support internal sync, pause, reexec
and shutdown. Sync reloads the published generation before reconciliation.
Reexec stops workers and replaces the supervisor's code in place after a manager
update, keeping its PID and init ownership and its control receivers. Shutdown
remains idempotent when init already sent TERM, removing unconsumed requests once
the supervisor exits.

Missing managed binaries download from the accepted URL while any tunnel is
desired. Download helpers are interruptible, bounded, and retry indefinitely from
approximately 30 seconds to five minutes, with jitter. Retry deadlines use epoch
time; correct clock and CA trust are prerequisites for HTTPS.

## Installation, updates and trust

`scripts/install.sh` performs first installation only, with no parameters or
prompts, and is safe to stream (`curl ... | sh`): the whole installer function is
parsed before it runs, so truncated streams execute nothing. Local releases use
their adjacent manager; streamed installers fetch `main` from the fixed GitHub
repository with verified HTTPS-only redirects and size/time bounds. Marker and
shell syntax are checked before invocation. These checks are not authenticity
guarantees: the repository must be trusted.

The installer refuses an existing `/usr/sbin/wtctl`, and refuses before changing
anything when no supported init system is detected. It creates a bootstrap
accepted state (no tunnels, control disabled) with the installed manager's URL
already accepted, writes a sample `wtctl.ini` with `REPLACE-ME` placeholders
that validation rejects, registers boot and starts the service.

All later software changes are URL changes in the configuration. Downloads and
compatibility validation happen before disrupting running clients. Downloads use
verified HTTPS-only redirects, size and time limits, matching native ELF
identity, and bounded `client --help` checks. They do not authenticate code or
prove full ISA/ABI compatibility. Trusted administrator-selected code executes as
root. No checksum/signature mandate.

Secrets remain root-only plaintext and may appear in privileged client argv.
Status output redacts them.

## Boot integration and diagnostics

OpenWrt/systemd/SysV adapters are detected by the installer. SysV requires
update-rc.d rather than printing a manual-registration suggestion. Managed
existing adapters are reused; unrelated files/symlinks are never overwritten.
`uninstall` removes managed adapters and their registration, and reports
unmanaged ones.

Doctor does not initialize state or execute init scripts. OpenWrt/SysV boot links
are inspected (readlink optional); systemd uses is-enabled. Missing tools,
permissions or unrecognized data report unknown, not enabled. Boot registration
is distinct from process state or actual connectivity. The dropbear receiver
capability is required only while control is enabled.

## Control receiver

Each receiver port is a dedicated dropbear instance on IPv4 loopback with a
forced `wtctl _handle` command, forwarding disabled and only blank-password
logins accepted ([ADR 0004](adr/0004-dropbear-control-receiver.md)). It logs in
through a wtctl-owned `wtctl` account with root's user ID, which exists only
while control is accepted as enabled. Activation and rollback add or remove it
under the configuration lock, editing only the entry marked
`wtctl control receiver`. The receiver host key lives in
`/etc/wtctl/control_host_key`. Per-connection dropbear output is discarded;
wtctl's event trail records requests.

## Deliberate exclusions

Interactive menus and wizards, per-record commands, server mode,
architecture-to-URL catalogs, archives, checksums/signatures, automatic
dependencies, arbitrary shell/headers, mTLS, traffic-health status, tunnel logs,
firewall configuration, legacy migration and unspecified hardware qualification.
