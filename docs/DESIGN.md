# Design (0.2.0)

## Boundaries

One root-operated POSIX-shell executable; Linux `/proc` supplies process identity.
No UCI, ubus or rpcd dependency in the core. Setup uses the existing init system
for boot registration and service ownership. The manager never changes firewall,
network interfaces, firmware, feeds, packages or unrelated processes. Help,
version and doctor remain non-root, read-only operations.

A foreground supervisor polls requests each second and normally reconciles every
five seconds. Mutation requests force immediate reconciliation before acknowledgment.
One shell worker per configured tunnel owns a client. Rapid client failures back
off from 2 to 30 seconds; surviving 60 seconds resets backoff. All client output
is discarded with `RUST_LOG=off`; no tunnel logs are stored.

## Data and automatic transactions

Persistent `/etc/wtctl` and runtime `/tmp/wtctl` are root-owned mode 0700. Files
are private; executables are mode 0700. Symlink path components and overlapping
roots are rejected. `WTCTL_CONFIG_DIR`/`WTCTL_STATE_DIR` are development overrides,
not supported by the device installer/startup adapters. Ancestors must be trusted.

Records are strict required `key=value` fields, one per line, never sourced or
evaluated. Unknown/duplicate fields and CR/LF fail closed. IDs use ASCII letters,
digits, underscore/hyphen, max 64 characters; `all` and `global` are reserved.

Schema **format=2**, fresh installs only:

- `global`: `format storage url max_kib reserve_kib`.
- `servers/NAME`: `endpoint auth prefix username password ca`.
- `tunnels/NAME`: `server direction protocol bind listen target port`.
- `bin/wstunnel`: managed persistent binary, when selected.

No enabled flag, external-binary mode, runtime start/stop overrides or public
apply operation exists. Every configured tunnel is desired, including after boot.

CLI mutations hold the config directory lock from record backup through complete
validation, immutable snapshot publication and supervisor acknowledgment. Atomic
rename publishes `current`. The internal snapshot layer is retained for rollback
and worker isolation, not as an exposed draft/apply workflow. Failure restores
both the previous saved record and current pointer, then reconciles the supervisor.
Caught termination signals also roll back. Successful tunnel deletion immediately
stops its worker/client. In-use server deletion fails.

Snapshot collection uses the same lock and retains generations used by workers.
Comparison of tunnel/server records and executable paths restarts only affected
workers. Shared-server edits restart each referencing tunnel. Global binary
changes can restart all workers. Direct manual editing is unsupported while the
manager runs; use CLI/wizard transactions.

All configured listeners are compared for conservative conflicts. Reverse
conflicts are scoped to the same profile. This is not an OS socket reservation:
unmanaged listeners, IPv6 aliases, and multiple profiles targeting one remote
server can still conflict. Worker acknowledgment means local worker startup,
not successful parsing by the client, socket binding or remote connectivity.
Client exits are retained and retried rather than misclassified as remote/local
configuration rollback evidence.

Transactions protect ordinary command failures and caught signals, **not durable
crash-atomicity across SIGKILL or power loss mid-transaction**. Publication is
atomic, but saved records/binary/pointer are separate files. Requalify abrupt
power-loss behavior before production acceptance; backup configuration before
maintenance. Uncertain rollback acknowledgment reports an error, not success.

## Ownership and recovery

PID files pair PID with `/proc/PID/stat` start time; zombies are considered exited.
Cleanup signals only recorded live owners. Supervisor recovery cleans owned
orphans, then restores every saved tunnel. procd/systemd supervise the manager;
manual background launch and SysV have no equivalent watchdog.

Root-private atomically published requests support internal sync, pause and
shutdown. Sync reloads the published generation before reconciliation; response
occurs after local worker startup. Shutdown remains idempotent when init already
sent TERM, removing unconsumed requests once the supervisor exits.

Missing managed binaries download while any tunnel is desired. Download helpers
are interruptible, bounded, and retry indefinitely from approximately 30 seconds
to five minutes, with jitter. Retry deadlines use epoch time; correct clock and
CA trust are prerequisites for HTTPS. No counters/history are written to flash.

## Setup/update safety and trust

`scripts/install.sh` is the single setup/update entry point. It validates arguments
and boot requirements, runs candidate manager code to configure the binary, then
installs that script, ensures boot registration and transfers supervisor ownership
to the service. Existing tunnels/settings are preserved. No URL means reuse;
explicit URL means download a replacement even if unchanged. RAM/persistent
storage is selectable; external binaries are not an exposed mode.

Download and compatibility validation happen before pausing running clients.
The old binary remains in place during network waits. Activation pauses the
supervisor, atomically renames the old executable to a backup, activates the
candidate, and resumes via sync. The backup is removed only after acknowledgment;
failures restore it and the old global record/pointer. Staging needs free space
for the candidate plus reserve while retaining the old executable. Downloads
use verified HTTPS-only redirects, size and time limits, matching native ELF
identity, and bounded `client --help` checks. These checks do not authenticate
code or prove full ISA/ABI compatibility. Trusted administrator-selected code
executes as root. No checksum/signature mandate.

Secrets remain root-only plaintext and may appear in privileged client argv.
Lists/status redact them. Hidden terminal entry uses stty; its absence requires
a private one-line password file.

## Menus and boot diagnostics

Fixed menus and confirmations use immediate single-key numeric choices; 0 means
Back/Exit/Cancel. Existing-record lists use 1–9 then a–z without pagination.
More than 35 records require numbered Enter-based input. Free-form values always
use line input. Optional stty noncanonical mode plus an interruptible background
byte reader avoid non-POSIX read extensions. Every read restores terminal settings
on completion, EOF and signals. Missing stty falls back to line input.

Setup always registers boot and starts the service. OpenWrt/systemd/SysV adapters
are detected or explicitly selected. SysV requires update-rc.d rather than merely
printing a manual-registration suggestion. Managed existing adapters are reused;
unrelated files/symlinks are not overwritten. Startup commands remain administrative
service plumbing for removal/diagnostics, not ordinary menu items.

Doctor does not initialize state or execute init scripts. OpenWrt/SysV boot links
are inspected (readlink optional); systemd uses is-enabled. Missing tools,
permissions or unrecognized data report unknown, not enabled. Boot registration
is distinct from process state or actual connectivity.

## Deliberate exclusions

Server mode, architecture-to-URL catalogs, archives, checksums/signatures,
automatic dependencies, arbitrary shell/headers, mTLS, traffic-health status,
tunnel logs, firewall configuration, legacy migration and unspecified hardware
qualification.
