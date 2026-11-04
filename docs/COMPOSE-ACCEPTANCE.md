# Compose acceptance lab

Run from the checkout:

```sh
make compose-test
```

Requires Docker Compose v2 and host Python 3. The runner creates a uniquely named,
disposable project, builds a checkout snapshot into the images, and removes its
containers and named volume on success or failure. Assertions fail the command;
failure output includes server logs and device activation diagnostics. Allow
15–30 minutes for image builds, real download/reconnection deadlines and real
60-second confirmation timeouts. This is not physical-device qualification.

The lab currently selects `linux/amd64` for the device and matching static client
artifact. Docker Desktop may emulate it on ARM hosts; this does not demonstrate
native CPU/ABI compatibility on an actual target device.

## Topology

- `wstunnel`: official `ghcr.io/erebe/wstunnel:v11.1.0`, native verified WSS,
  shared-secret HTTP-upgrade path restriction.
- `device`: root-operated Alpine/BusyBox running the real installer and wtctl.
  Initially has neither an installed manager, managed binary nor activation state.
- `sources`: verified HTTPS software source serving the checkout manager and
  checksum-verified static executable from the upstream v11.1.0 release. Records real requests and serves
  controlled invalid/unavailable artifacts.
- `operator`: plain BusyBox `nc` sends protocol streams to forwarded listeners
  on `wstunnel`, never directly to the device loopback receiver.
- `server-target` and the device's echo targets: separate TCP/UDP traffic endpoints.
- `init`: generates an ephemeral CA, DNS-valid server certificate, and download
  artifacts. These are test secrets, not production credentials.

An internal Docker network has no published host ports by default. Only the
artifact image contains the source executable; the device must obtain its
managed executable through the real HTTPS download path. No activation-state
files are seeded by the acceptance runner.

The device's `/tmp` tmpfs explicitly enables execution: RAM storage runs the
downloaded executable there. Docker's default noexec tmpfs is not suitable for
that mode; this is a deployment prerequisite, not a disabled test check.

## Prefix and TLS configuration

The official image uses dumb-init, not wstunnel itself, as its entrypoint. Its
command explicitly includes the binary:

```yaml
command:
  - /home/app/wstunnel
  - server
  - --tls-certificate
  - /lab/server.pem
  - --tls-private-key
  - /lab/server.key
  - --restrict-http-upgrade-path-prefix
  - test-secret-prefix
  - wss://0.0.0.0:8080
```

The device uses `auth=path`, `prefix=test-secret-prefix`,
`endpoint=wss://wstunnel:8080` and `ca=/lab/ca.pem`. The wrong-prefix test must
fail candidate confirmation and roll back. TLS verification remains enabled.

**A path-prefix secret authenticates tunnel establishment, not users reaching a
forwarded listener.** Never publish the control port to an untrusted network.

## Manual netcat experiments

Use a different project from automated tests:

```sh
docker compose -p wtctl-manual -f tests/compose/compose.yaml \
  -f tests/compose/manual.yaml up -d --build --wait
```

The override binds WSS and control listeners only to `127.0.0.1` on your host.
It does not install a desired configuration automatically. Start with
`cp tests/compose/device.ini device.ini`, edit it as desired, copy it into the
device, and run the installer:

Validate this example inside the device container: its CA path `/lab/ca.pem`
exists in the lab, not on your host.

```sh
docker compose -p wtctl-manual -f tests/compose/compose.yaml \
  cp device.ini device:/tmp/device.ini
docker compose -p wtctl-manual -f tests/compose/compose.yaml \
  exec -T device sh /work/scripts/install.sh --yes --config /tmp/device.ini --startup sysv
```

Set the remote control bind to `0.0.0.0` and listen to `8099`. On PENDING, confirm:

```sh
{ printf 'PUT %s\n' "$(wc -c < device.ini | tr -d ' ')"; cat device.ini; sleep 10; } |
  nc -w 240 127.0.0.1 18099
{ printf 'GET ACTIVE\n'; sleep 3; } | nc -w 10 127.0.0.1 18099
```

Keep the sender's input open long enough to receive the response. BusyBox nc
with stdin already at EOF can close a wstunnel v11.1.0 reverse stream before
the response arrives. The automated operator keeps stdin open until the
length-framed response is complete; it still transmits using the real nc
executable, not a replacement socket client. For a slow download/application,
use a longer input-hold interval than the confirmation example above. Desktop
netcat variants may provide their own half-close/EOF options; do not assume they
match BusyBox behavior.

The INI installer hands supervision to the selected init adapter after activation
finishes. For an enabled-control install it returns PENDING first; handoff waits
for confirmation or rollback and records diagnostics in
`/tmp/wtctl/install-handoff.log`. The lab asserts completion separately from
configuration acceptance.

Port `18100` maps a candidate remote listener at `8100` when testing a changed
control port. This differs from the private device-side receiver port, which is
runtime state and must not be contacted directly to confirm reachability.

Cleanup your manual lab explicitly:

```sh
docker compose -p wtctl-manual -f tests/compose/compose.yaml \
  -f tests/compose/manual.yaml down --volumes
```

## Honest limits

This lab is an executable acceptance specification: a failure means the scenario
is not accepted, even when earlier groups passed. Do not count image startup or
partial progress as a successful suite. The runner exits nonzero on assertions.

The SysV registration recorder is a test double, not an init system. Generated
SysV start/stop scripts can execute real wtctl commands; Docker entrypoint restart
recovery is not evidence of real boot ordering. Actual procd/systemd, firmware
ABI/resource limits, power loss and device WAN behavior require qualification on
the supported device or an appropriate VM. See [CONTROL-QUALIFICATION.md](CONTROL-QUALIFICATION.md).

The installer adapter matrix additionally uses test-only `rc.common`/procd and
`systemctl` doubles. They inspect the unchanged generated adapter and execute its
real daemon command; they do not validate the actual init implementation.

Software variants keep real wstunnel behavior: the test source appends distinct
trailing markers to the static ELF for byte-level replacement/rollback checks.
Manager variants change the reported lab version. This is evidence of executable
replacement and restoration, not interoperability across different upstream
wstunnel releases.
