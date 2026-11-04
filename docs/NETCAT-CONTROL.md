# Netcat configuration streams

`wtctl apply device.ini` and `cat device.ini | wtctl apply -` submit a complete
configuration. Validate without changing the device using `wtctl validate device.ini`.
The INI schema is described in [CONTROL-CONFIG-DESIGN.md](CONTROL-CONFIG-DESIGN.md).

Install noninteractively with:

```sh
sh scripts/install.sh --yes --config device.ini --startup openwrt
```

There is no dedicated remote client. On the device, the supported BusyBox `nc`
must provide `-lk -s ADDRESS -p PORT -e HANDLER`. The receiver binds to IPv4
loopback; wstunnel publishes it through the configured reverse control tunnel.
This is not compatible with arbitrary desktop netcat listener implementations.

## Security

**Restrict the server-side forwarded TCP port using a firewall or private network.**
There is no application authentication. Anyone able to connect can retrieve
configuration secrets and submit root-level executable updates. WSS alone does
not authenticate users connecting to the forwarded TCP port.

## Requests from an operator machine

```sh
printf 'GET\n' | nc -w 5 SERVER CONTROL_PORT
printf 'GET ACTIVE\n' | nc -w 5 SERVER CONTROL_PORT
printf 'STATUS\n' | nc -w 5 SERVER CONTROL_PORT
{ printf 'PUT %s\n' "$(wc -c < device.ini | tr -d ' ')"; cat device.ini; } |
    nc -w 240 SERVER CONTROL_PORT
```

Use one request per connection. Headers end in LF, not CRLF. PUT carries exactly
the declared number of bytes, at most 65536. The header is limited to 128 bytes;
the entire request must arrive within 15 seconds. Trailing data is not another
request. Do not infer payload length from TCP packet/read boundaries.

Successful reads return `OK BYTE_COUNT\n` followed by exactly those payload
bytes. STATUS payload is one newline-terminated line: `idle`, `applying`,
`awaiting-confirmation`, or `failed REASON`. Successful activation returns
`OK 0\n`. Failure returns `KO REASON\n`. Reasons currently include
`invalid-request`, `invalid-configuration`, `unavailable`, `download-failed`,
`manager-download-failed`, `activation-failed`, `confirmation-timeout`,
`superseded`, and `activation-process-lost`.

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

The legacy setup/menu and per-record commands remain available for older
installations; per-record mutations and legacy setup are rejected after the
first accepted INI activation. Physical-device and real
forwarded-traffic qualification remain required before production deployment.
