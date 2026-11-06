# Remote control

`wtctl apply device.ini` and `cat device.ini | wtctl apply -` submit a complete
configuration locally. Validate without changing the device using
`wtctl validate device.ini`. The INI schema is described in
[CONTROL-CONFIG-DESIGN.md](CONTROL-CONFIG-DESIGN.md).

With `[control] enabled=true` the same requests can be sent remotely through a
reverse tunnel to the configured server. There is no dedicated client: the
operator uses plain `ssh`, with no keys and no password.

## How it works

The device runs a dedicated dropbear instance per control receiver, bound to
IPv4 loopback and published on the server by the reverse control tunnel. Each
connection runs `wtctl _handle` as a forced command, so stdin carries the
request and stdout the response. Receivers accept only the `wtctl` account,
which has root's user ID and a blank password. Port forwarding is disabled.
The device's normal SSH service refuses blank-password logins, so it doesn't
accept that account.

- The account exists only while control is accepted as enabled. Activation adds
  it before the candidate receiver starts. Disabling control, a rollback to a
  setup without control, and `uninstall` remove it. Only an entry whose comment
  field is `wtctl control receiver` is ever changed. If a different `wtctl`
  account exists, activation fails with `KO control-unavailable`.
- The receiver host key is generated once in `/etc/wtctl/control_host_key` and
  kept until `uninstall --purge`. Nobody is expected to verify it.
- Requirements: `dropbear` and `dropbearkey`. They're included in standard
  OpenWrt images. Elsewhere, install dropbear to use remote control. Without
  them, `apply` with control enabled fails with `KO control-unavailable` and the
  previous setup stays in place. `doctor` reports the capability.

## Security

**Restrict the server-side forwarded port using a firewall or private network.**
There is no authentication. Anyone able to connect can retrieve configuration
secrets and submit root-level executable updates. SSH here only provides a
listener and encryption, not access control. A blank-password, root-equivalent
`wtctl` account exists while control is enabled. Normal SSH refuses it, and LuCI
only accepts users listed in `/etc/config/rpcd`. A local password prompt (serial
console, `su`) would accept it.

## Requests from an operator machine

```sh
SSH='ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR'
printf 'GET\n' | $SSH -p CONTROL_PORT wtctl@SERVER
printf 'GET ACTIVE\n' | $SSH -p CONTROL_PORT wtctl@SERVER
printf 'STATUS\n' | $SSH -p CONTROL_PORT wtctl@SERVER
{ printf 'PUT %s\n' "$(wc -c < device.ini | tr -d ' ')"; cat device.ini; } |
    $SSH -p CONTROL_PORT wtctl@SERVER
```

On OpenWrt, `dbclient -y -y -T -p CONTROL_PORT wtctl@SERVER x` is equivalent.

Use one request per session. Headers end in LF, not CRLF. PUT carries exactly
the declared number of bytes, at most 65536. The header is limited to 128 bytes;
the entire request must arrive within 15 seconds. Trailing data is not another
request.

Successful reads return `OK BYTE_COUNT\n` followed by exactly those payload
bytes. STATUS payload is one newline-terminated line: `idle`, `applying`,
`awaiting-confirmation`, or `failed REASON`. Successful activation returns
`OK 0\n`. Failure returns `KO REASON\n`. Reasons currently include
`invalid-request`, `invalid-configuration`, `unavailable`, `control-unavailable`,
`download-failed`, `manager-download-failed`, `insufficient-space`, `activation-failed`,
`confirmation-timeout`, `superseded`, and `activation-process-lost`.

When PUT or local apply returns `PENDING confirmation-required`, connect to the
**candidate server address and control port** and send the same PUT, containing
byte-for-byte identical INI bytes. The candidate connection receives the final
result. Arrival on the previous receiver does not confirm the candidate. The
60-second deadline starts after staging and supervisor startup. The old control
path is retained where listener bindings permit; same-listener replacement can
interrupt access. Downloads are limited to 180 seconds each, with a 20-second
connection timeout. Allow sufficient client time for both downloads and restart.

## State and failure semantics

`desired.ini` retains the most recent valid submission; `active.ini` advances only
after complete success. `activation-state` records accepted software URLs.
Changed URLs request downloads; unchanged URLs do not request an update. Startup
uses the accepted snapshot, not a failed desired draft. Resubmit explicitly to
retry. A running independent shell coordinator attempts rollback on failure;
power-loss/crash-atomic rollback is not promised. A newer different submission
supersedes an older pending candidate and waits for serialized activation.

Physical-device and real forwarded-traffic qualification remain required before
production deployment.
