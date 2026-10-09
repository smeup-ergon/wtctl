# Design

## Boundaries

`wtctl` is one POSIX-shell executable. Linux `/proc` supplies process identity;
no UCI, ubus, rpcd or init-system APIs are used by the core. Startup adapters are
optional. The manager owns only client processes it launches. It never changes
firewall, network interfaces, WAN listeners, firmware, vendor feeds, or the old
project. Root is required for all operational commands; help/version/doctor are
read-only and do not require root.

One foreground supervisor polls commands each second and scans/reconciles
processes approximately every five seconds. One lightweight shell worker per
wanted tunnel owns one wstunnel client and waits for it. Rapid failures back off
from 2 to 30 seconds; a client surviving 60 seconds resets backoff. Client stdout
and stderr go to `/dev/null`, with `RUST_LOG=off`. No tunnel logs are stored.

## Data and configuration

Default persistent root: `/etc/wtctl`; runtime root: `/tmp/wtctl`. Both are root
owned and mode 0700; created files are mode 0600. Paths with symlink components
are rejected, and persistent/runtime roots may not overlap. Overrides
`WTCTL_CONFIG_DIR` and `WTCTL_STATE_DIR` support isolated development, not
startup adapters. Use trusted ancestor directories; custom paths must not be
under directories writable by untrusted users.

Configuration records are `key=value`, one field per line. Values may include
spaces, `=` and shell metacharacters, but not CR/LF. Keys are fixed and required;
unknown/duplicate fields fail validation. No record is sourced or evaluated.
Names use ASCII letters/digits/underscore/hyphen, at most 64 characters; `all`
and `global` are reserved. The global `format=1` identifies the data schema.

- `global`: `format`, `storage`, `url`, `external`, `max_kib`, `reserve_kib`.
- `servers/NAME`: `endpoint`, `auth`, `prefix`, `username`, `password`, `ca`.
- `tunnels/NAME`: `server`, `direction`, `protocol`, `bind`, `listen`, `target`,
  `port`, `enabled`.
- `bin/wstunnel`: persistent managed executable, when selected.

CLI writes serialize through an atomic directory lock and rename replacement
records. Direct manual editors must not run concurrently with CLI writes/apply.
`apply` validates the entire draft and copies immutable per-tunnel/server records
into a persistent `applied/` generation, publishing its `current` path by atomic
rename. Thus draft edits cannot accidentally change running clients or become
active merely because RAM state was lost at reboot. Applied snapshots are tiny
configuration copies, not binary copies; they are written only on explicit apply
(or first launch when no initial snapshot exists). A config lock also serializes
snapshot collection; generations used by workers remain available. The
supervisor compares records and restarts only affected tunnels. Global binary
settings changes may restart all tunnels. Only explicit update deletes a managed
binary; changing its URL alone does not replace an existing executable.

Enabled configured listeners with the same direction/protocol/port and
conflicting bind addresses are rejected. Reverse conflicts are scoped to the
same profile. This is conservative configuration conflict detection, **not a
full OS socket reservation mechanism**. Unmanaged listeners, IPv6 aliases and
multiple profile names referring to one remote server can still conflict;
wstunnel exits/retries and status exposes process failures. Arbitrary IPv6 text
matching the allowed syntax is ultimately checked by wstunnel's parser.

## Ownership, requests and recovery

PID files pair PID with Linux `/proc/PID/stat` start time. A stale PID alone can
never authorize a signal. Zombies are treated as exited. Cleanup targets only
recorded workers, child clients and download processes; no `killall`/`pkill`.
Supervisor restart first cleans owned orphans and resets temporary start/stop
overrides, then restores enabled tunnels. procd/systemd keep the supervisor alive.
Manual background launch has no external crash watchdog.

Commands use root-private request/response files, atomically published, with
fixed action/name fields. Commands acknowledge queuing/lifecycle changes, not
verified traffic success. If init already sent TERM, observing the owned
supervisor exit also satisfies shutdown; its unconsumed shutdown request is
removed so it cannot affect the next supervisor. State is runtime-only; no restart counter/history is
written to flash. Explicit updates leave a runtime recovery marker until success
or `stop all`, allowing recovery after a supervisor crash.

Download workers are interruptible and have bounded curl operations. Missing
RAM binaries recover while tunnels are wanted. Retry deadlines use epoch time;
correct the device clock for TLS before expecting a successful download. Clock
changes may alter backoff timing. Network-ready ordering is helpful but not
required: recovery continues through outages.

## Trust model

An administrator-selected HTTPS URL serves a raw ELF executable, not an archive.
TLS stays verified. No checksum/signature requirement is imposed. ELF identity
and bounded `client --help` check basic compatibility, not authenticity, ISA
level, float ABI, kernel support, or complete runtime behavior. Validation
executes downloaded code as root: trust the source accordingly.

Secrets are root-readable plaintext. Client argv may expose credentials to
privileged process inspection. CLI status/listings redact endpoints, prefixes,
usernames/passwords and CA paths. Hidden menu entry requires `stty`; CLI accepts
a one-line password file. Neither mechanism removes secrets from wstunnel argv.

Updates intentionally mirror the old manager: stop clients, delete the old
managed executable, download, validate, activate. Space is preflighted before
deleting; no rollback binary exists. Download failure means downtime, with
indefinite capped retries. Externally supplied binaries live outside manager-owned
roots and are never updated or deleted.

## Deliberate exclusions

Server mode, automatic architecture-to-URL catalogs, archive extraction,
checksums/signatures, rollback, automatic dependency installation, arbitrary
shell/headers, mTLS, connected/traffic-health status, tunnel logs, firewall
configuration, and physical qualification of unspecified distros/devices.
