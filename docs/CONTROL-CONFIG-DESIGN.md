# Configuration-driven management and control tunnel

Status: design confirmed; implementation in progress. This describes a replacement management model, not current implemented behavior except where explicitly noted.

Implementation and operator instructions: [NETCAT-CONTROL.md](NETCAT-CONTROL.md).
The remote sender is plain netcat, not a dedicated management application.

## Scope

- Replace interactive wizards/menus and per-record mutation workflows with one complete INI desired configuration.
- Local `wtctl apply FILE` and remote submissions use the same validation and activation path.
- No file watcher, configuration revisions, merge semantics, custom cryptography, or additional runtime dependencies.
- Preserve existing platform, storage, download-safety, authentication, custom-CA, and service-adapter capabilities unless explicitly changed here.
- Add a dedicated control receiver and control tunnel; exclude control from ordinary tunnel listings and expose dedicated control status.

## Configuration and persisted state

Persist the desired configuration, last successfully active configuration, and a separate activation-state file. Activation state records accepted software URLs and control settings; it is not an independent configuration source.

The latest valid submitted configuration wins, regardless of local or remote origin. Invalid input must not replace desired configuration. A valid submission that fails activation remains desired, while the previous complete active configuration is restored. Do not automatically retry its activation, including after reboot. Explicitly resubmitting it retries activation.

Startup restores the active configuration, not a failed desired configuration. Recover missing accepted RAM-resident software from its accepted URL with existing retry behavior. Accepted ordinary tunnels and enabled control connectivity retain runtime supervision and reconnection.

Example complete configuration:

```ini
[wtctl]
format=1
url=https://downloads.example/wtctl-v1
wstunnel_url=https://downloads.example/wstunnel-v1
storage=ram

[control]
enabled=true
server=primary
bind=::
listen=8099

[server primary]
endpoint=wss://my.server.com
auth=none

[tunnel ssh]
server=primary
direction=reverse
protocol=tcp
bind=127.0.0.1
listen=2222
target=localhost
port=22
```

- Software URLs and the control section are required; control defaults to enabled when its `enabled` field is omitted.
- Ordinary tunnel omission means deletion.
- Retain existing server authentication and custom-CA capabilities.
- Retain download-size/free-space protections, with defaults and optional configuration fields.
- Permit blank lines and whole-line comments. No inline comments, interpolation, includes, shell evaluation, or expansion.
- Split assignments at the first `=`. Reject unknown or duplicate fields/sections and invalid references or listener conflicts.
- The initial parser accepts printable ASCII, tabs and LF newlines only; CRLF and NUL are rejected. Leading/trailing spaces and tabs around lines, keys and values are trimmed. Whole-line comments start with `#` or `;`. Values are otherwise literal, including `=` and inline comment characters.
- `wtctl validate FILE` performs offline validation without modifying live configuration. It does not apply the configuration.

## Software activation

Both software source URLs belong to desired configuration. Compare them with last successfully activated URLs, not last attempted URLs. Unchanged URLs do not request an update, even if remote content changed; a changed URL, including a query component, requests an update. There is no force-update command.

Stage and validate downloads before disrupting the working setup. Treat the configuration as a whole: activation failure restores prior software, control settings, and ordinary tunnels on a best-effort basis while the activation process remains alive. Only complete success advances active configuration and activation state.

Keep an independent activation process alive across replacement/restart of the managed wtctl process so it can report success or attempt rollback. Do not promise crash-atomic behavior, power-loss recovery, or rollback after loss of that activation process. Updating wstunnel can interrupt the control connection.

## Control topology and security boundary

Normal topology is equivalent to:

```sh
wstunnel client -R 'tcp://[::]:8099:localhost:8099' wss://my.server.com
```

The device initiates WSS to an existing remote server. The server listens on all IPv6 interfaces at port 8099; IPv4 reachability depends on the server's socket behavior. The receiver on the device is loopback-only. The WSS server port is independent of the forwarded control port.

Existing tunnel security is retained; no application-level authentication is added. WSS does not authenticate clients connecting directly to the server's forwarded TCP port. Anyone reaching that port can read configuration secrets and request root-level executable replacement. Server firewall/network restrictions are therefore essential to restrict management access. Separate devices require distinct server-side listener addresses or ports.

Control can be explicitly disabled. Retain its settings but do not treat untested disabled settings as verified. Disabling control remotely is permitted: complete other activation checks, send success, then close the tunnel. Subsequent remote access is unavailable until control is re-enabled locally.

## Candidate confirmation

Require identical-draft resubmission through a candidate control connection when:

- enabling control;
- changing control connectivity, including referenced server settings;
- changing either software URL while control remains enabled.

Changes confined to ordinary tunnels or unrelated settings do not require confirmation. With control disabled throughout, local activation needs no remote confirmation.

Use a separate temporary loopback receiver for the candidate tunnel so arrival through the old tunnel cannot confirm the candidate. The candidate's server-side listener uses the configured address and port; its device-side target can differ internally. That internal target is runtime state and may remain until restart.

Keep old control connectivity while testing when listener bindings permit. If the candidate needs the same occupied server listener, temporarily stop the old connection, try the candidate, and restore the old connection on failure. Outage-free replacement is not guaranteed.

Confirmation requires byte-for-byte identical configuration bytes. Start a 60-second confirmation deadline once the candidate starts, excluding downloads. Failure or timeout rejects activation and attempts rollback. Confirmation is an activation check only: ordinary reconnections of accepted control connectivity need no resubmission.

## Protocol

One request per TCP connection; configuration payloads are length-framed, never inferred from socket read boundaries.

| Request | Meaning |
| --- | --- |
| `GET` | Retrieve desired configuration. |
| `GET ACTIVE` | Retrieve last accepted active configuration. |
| `STATUS` | Retrieve idle/applying/awaiting-confirmation/failed state and last failure reason. |
| `PUT <byte-count>` followed by exactly that many bytes | Submit a complete configuration or confirm an identical pending draft through the candidate receiver. |

Request headers terminate with a newline. Configuration responses carry a byte count and exact payload bytes. Responses distinguish:

- `OK`: activation completed successfully, or the requested read succeeded.
- `KO` plus a short reason: request or activation failed.
- `PENDING confirmation-required`: candidate confirmation is needed before activation can complete.

After `PENDING`, the tool connects through the candidate and submits identical bytes; that connection receives the final result. The original connection may disappear. Reconnect and use status/configuration reads to resolve uncertainty; repeating a failed desired configuration explicitly retries it.

Maximum configuration size is 64 KiB. Request-read timeout is 15 seconds. Each download has a 180-second deadline and 20-second connect timeout; draft download failures are reported without automatic retry. Response framing, status payload grammar, and reason codes are specified in [NETCAT-CONTROL.md](NETCAT-CONTROL.md), without additional protocol operations.

## Concurrent submissions

Serialize activations. A newer different valid submission replaces desired configuration and invalidates older pending confirmation. Never interrupt executable replacement at an unsafe point: finish or roll back the current safe stage before activating the newest desired configuration. Intermediate superseded submissions need not activate.

Identical draft arrival through the candidate receiver confirms the current attempt; it does not enqueue another activation. An old confirmation cannot activate a superseded draft. Do not introduce client-visible revision management.

## First installation

Provide a noninteractive installer accepting an initial INI file. Install and enable the service. Establish a minimal bootstrap active configuration with control disabled and no ordinary tunnels, then attempt the submitted desired configuration.

If control is enabled, require identical-draft submission through candidate connectivity before reporting successful activation. On failure or confirmation timeout, stop candidate tunnels, retain bootstrap active state, leave the desired file available, and require explicit local resubmission to retry. An initial configuration disabling control can activate without remote confirmation.

## Acceptance scenarios

- Identical local and remote submissions use identical validation and activation semantics.
- Omitting an ordinary tunnel removes it; its process failure instead triggers supervision.
- Failed URL changes return failure, leave successful URLs unchanged, and are not retried on reboot.
- Missing accepted RAM binaries are recovered from accepted URLs with retries.
- Identical bytes through the old receiver cannot confirm a candidate.
- Candidate confirmation timeout restores the prior complete working setup when rollback remains possible.
- A newer draft invalidates older confirmation without concurrent software replacement.
- Ordinary tunnel-only edits need no control confirmation.
- Software updates with enabled control require post-change end-to-end confirmation.
- Remote control disabling returns success before removing its management path.
- No enabled-control confirmation is required for changes that keep control disabled.
- Boot uses active configuration even when desired configuration records a failed draft.
- Control never appears as an ordinary managed tunnel and remains supervised even with zero ordinary tunnels.

## Implementation feasibility gate

The current shell program has no network request receiver. Before building, verify a bounded loopback TCP listener and bidirectional protocol implementation against the existing supported BusyBox/POSIX environment. Do not silently assume a particular `nc`/`inetd` variant or add a dependency. If the existing baseline cannot provide the receiver, bring that constraint back for a decision rather than changing the agreed dependency policy.
