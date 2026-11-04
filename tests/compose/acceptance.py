"""Cross-container acceptance tests. All remote configuration traffic uses nc.

Run through run.sh, never against a production Compose project.
"""
import concurrent.futures
import os
from pathlib import Path
import subprocess
import time


COMPOSE = ["docker", "compose", "-p", os.environ["WTCTL_TEST_PROJECT"],
           "-f", os.environ.get("WTCTL_COMPOSE_FILE", str(Path(__file__).with_name("compose.yaml")))]
CHECKS = 0


def compose(*args, data=None, check=True, timeout=300):
    result = subprocess.run(COMPOSE + list(args), input=data, capture_output=True, timeout=timeout)
    if check and result.returncode:
        raise AssertionError(f"compose {' '.join(args)} failed:\n{result.stdout.decode()}\n{result.stderr.decode()}")
    return result


def execute(service, *args, data=None, check=True, timeout=300):
    return compose("exec", "-T", service, *args, data=data, check=check, timeout=timeout)


def device(*args, **kwargs):
    return execute("device", *args, **kwargs)


def shell(script, **kwargs):
    return device("sh", "-c", script, **kwargs)


def read(path):
    return device("cat", path).stdout


def eventually(predicate, description, seconds=90):
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        try:
            value = predicate()
            if value:
                return value
        except (AssertionError, OSError, subprocess.SubprocessError) as error:
            last = error
        time.sleep(1)
    raise AssertionError(f"Timed out waiting for {description}: {last}")


def passed(description):
    global CHECKS
    CHECKS += 1
    print(f"ok {CHECKS} - {description}", flush=True)


def draft(*, enabled=True, prefix="test-secret-prefix", control_port=8099,
          manager="manager", binary="binary", storage="ram", tunnels=True, target_port=17080):
    text = f"""[wtctl]
format=1
url=https://sources:8443/{manager}
wstunnel_url=https://sources:8443/{binary}
storage={storage}
[control]
enabled={'true' if enabled else 'false'}
server=primary
bind=0.0.0.0
listen={control_port}
[server primary]
endpoint=wss://wstunnel:8080
auth=path
prefix={prefix}
ca=/lab/ca.pem
"""
    if tunnels:
        for name, direction, protocol, listen, target, port in (
            ("ft", "forward", "tcp", 19001, "server-target", target_port),
            ("fu", "forward", "udp", 19002, "server-target", 17081),
            ("rt", "reverse", "tcp", 19003, "device", target_port),
            ("ru", "reverse", "udp", 19004, "device", 17081),
        ):
            text += f"""[tunnel {name}]
server=primary
direction={direction}
protocol={protocol}
bind=0.0.0.0
listen={listen}
target={target}
port={port}
"""
    return text.encode()


def local_apply(config):
    return device("/usr/sbin/wtctl", "apply", "-", data=config, check=False).stdout


def install(config, adapter="sysv"):
    device("sh", "-c", "cat > /tmp/initial.ini", data=config)
    return device("sh", "/work/scripts/install.sh", "--yes", "--config", "/tmp/initial.ini",
                  "--startup", adapter, check=False)


def remote(payload, port=8099, timeout=240):
    # No Python socket implementation stands in for the operator's nc.
    # Keep nc stdin open until the one-request receiver closes its response;
    # EOF/half-close before the reply can tear down a WSS reverse stream.
    driver = """import signal,subprocess,sys
signal.signal(signal.SIGALRM,lambda *_: (_ for _ in ()).throw(TimeoutError('nc response deadline')))
signal.alarm(int(sys.argv[2]))
p=subprocess.Popen(['nc','-w',sys.argv[2],'wstunnel',sys.argv[1]],stdin=subprocess.PIPE,stdout=subprocess.PIPE)
try:
 p.stdin.write(sys.stdin.buffer.read()); p.stdin.flush()
 header=p.stdout.readline(); sys.stdout.buffer.write(header)
 if header.startswith(b'OK '):
  remaining=int(header[3:]); body=b''
  while remaining:
   part=p.stdout.read(remaining)
   if not part: break
   body+=part; remaining-=len(part)
  sys.stdout.buffer.write(body)
finally:
 p.stdin.close()
 try: p.wait(timeout=2)
 except subprocess.TimeoutExpired: p.terminate(); p.wait(timeout=5)
"""
    return execute("operator", "python3", "-c", driver, str(port), str(timeout),
                   data=payload, check=False, timeout=timeout + 20).stdout


def put(config, port=8099, timeout=240):
    return remote(f"PUT {len(config)}\n".encode() + config, port, timeout=timeout)


def get(operation="GET ACTIVE", port=8099):
    response = remote((operation + "\n").encode(), port, timeout=10)
    header, separator, body = response.partition(b"\n")
    assert separator and header.startswith(b"OK "), response
    assert int(header[3:]) == len(body), response
    return body


def await_pending(config):
    eventually(lambda: read("/tmp/wtctl/activation") == b"awaiting-confirmation\n",
               "candidate awaiting confirmation")
    assert read("/etc/wtctl/desired.ini") == config


def confirm(config, port=8099):
    # Retry a connection only while candidate WSS listener is coming up.
    eventually(lambda: get("STATUS", port) == b"awaiting-confirmation\n", "candidate listener")
    assert put(config, port) == b"OK 0\n"
    eventually(lambda: get(port=port) == config, "accepted config")


def accepted(config):
    assert read("/etc/wtctl/active.ini") == config
    eventually(lambda: read("/etc/wtctl/current") == read("/etc/wtctl/accepted-current"),
               "accepted snapshot publication")


def probe(service, host, protocol, port):
    code = """import socket,sys
host,protocol,port=sys.argv[1:]
kind=socket.SOCK_STREAM if protocol=='tcp' else socket.SOCK_DGRAM
with socket.socket(socket.AF_INET,kind) as s:
 s.settimeout(3); s.connect((host,int(port))); s.sendall(b'compose-traffic'); assert s.recv(128)==b'compose-traffic'
"""
    return execute(service, "python3", "-c", code, host, protocol, str(port), check=False).returncode == 0


def traffic():
    for service, host, protocol, port in (
        ("device", "127.0.0.1", "tcp", 19001), ("device", "127.0.0.1", "udp", 19002),
        ("operator", "wstunnel", "tcp", 19003), ("operator", "wstunnel", "udp", 19004),
    ):
        eventually(lambda: probe(service, host, protocol, port), f"{protocol} {host}:{port}")


def reset_device():
    compose("rm", "--stop", "--force", "device")
    # /etc and /usr/sbin live only in the removed container; /tmp is tmpfs.
    compose("up", "-d", "--no-deps", "--wait", "device")
    assert shell("test ! -e /etc/wtctl/activation-state && test ! -e /usr/sbin/wtctl").returncode == 0


def downloads():
    result = execute("sources", "cat", "/lab/downloads.jsonl", check=False)
    return result.stdout


def main():
    reset_device()
    disabled = draft(enabled=False)
    result = install(disabled)
    assert result.returncode == 0 and b"OK 0\n" in result.stdout, (result.stdout, result.stderr)
    accepted(disabled)
    assert b"wtctl defaults" in read("/lab/registration.log")
    traffic()
    assert b"/manager" in downloads() and b"/binary" in downloads()
    passed("fresh --config install: verified HTTPS downloads, registration, four real tunnel modes")

    # Separate local apply semantics before moving on to a pristine remote case.
    local_edit = disabled + b"# local complete replacement\n"
    assert local_apply(local_edit) == b"OK 0\n"
    accepted(local_edit)
    traffic()
    passed("local stdin submission uses the same complete-configuration activation path")

    # Invalid input must be rejected before installer changes an existing device.
    before = read("/usr/sbin/wtctl")
    invalid = disabled.replace(b"format=1", b"format=99")
    result = install(invalid)
    assert result.returncode != 0
    assert read("/usr/sbin/wtctl") == before
    accepted(local_edit)
    passed("invalid installer INI leaves existing executable and active state intact")

    reset_device()
    initial = draft()
    result = install(initial)
    assert result.returncode == 0 and b"PENDING confirmation-required" in result.stdout, (result.stdout, result.stderr)
    assert shell("test ! -f /etc/wtctl/active.ini").returncode == 0
    confirm(initial)
    accepted(initial)
    eventually(lambda: shell("test -f /tmp/wtctl/install-handoff-complete", check=False).returncode == 0,
               "post-confirmation init handoff")
    eventually(lambda: get() == initial, "control after initial init handoff")
    traffic()
    assert get("GET") == initial
    passed("fresh enabled-control installer and identical-byte confirmation through server using nc")

    registration_before = read("/lab/registration.log")
    result = install(initial)
    assert result.returncode == 0 and b"OK 0\n" in result.stdout, (result.stdout, result.stderr)
    accepted(initial)
    assert shell("test -f /tmp/wtctl/install-handoff-complete").returncode == 0
    eventually(lambda: get() == initial, "control after repeated installer init handoff")
    assert len(read("/lab/registration.log")) > len(registration_before)
    assert get() == initial
    traffic()
    passed("rerunning --config installer preserves accepted setup and re-enables boot registration")

    unchanged_downloads = downloads()
    edited = draft(target_port=17080) + b"# ordinary-only comment\n"
    assert put(edited) == b"OK 0\n"
    accepted(edited)
    assert downloads() == unchanged_downloads, "unchanged URLs downloaded again"
    traffic()
    passed("remote ordinary-only edit needs no confirmation or software download")

    fewer = edited.split(b"[tunnel ru]\n")[0]
    assert put(fewer) == b"OK 0\n"
    accepted(fewer)
    eventually(lambda: shell("test ! -d /tmp/wtctl/tunnels/ru", check=False).returncode == 0,
               "omitted UDP tunnel removed")
    assert put(edited) == b"OK 0\n"
    traffic()
    passed("ordinary tunnel omission deletes it; resubmission restores real traffic")

    invalid_response = remote(b"PUT 65537\n", timeout=20)
    assert invalid_response == b"KO invalid-request\n", invalid_response
    started = time.monotonic()
    invalid_response = remote(b"PUT 5\nabc", timeout=25)
    assert invalid_response == b"KO invalid-request\n", invalid_response
    assert time.monotonic() - started < 22, "request remained open beyond server read deadline"
    assert shell("ps -ef | grep '[d]d bs=1'", check=False).returncode != 0, "orphan socket reader"
    accepted(edited)
    passed("oversized and incomplete nc streams rejected without changing active state")

    fragmented = edited + b"# fragmented request\n"
    framed = f"PUT {len(fragmented)}\n".encode() + fragmented
    # Separate writes and a delay force the receiver to handle socket short reads.
    script = "import subprocess,sys,time; p=subprocess.Popen(['nc','-w','60','wstunnel','8099'],stdin=subprocess.PIPE,stdout=subprocess.PIPE); data=sys.stdin.buffer.read(); p.stdin.write(data[:40]); p.stdin.flush(); time.sleep(1); p.stdin.write(data[40:]); p.stdin.flush(); sys.stdout.buffer.write(p.stdout.readline()); p.stdin.close(); p.terminate(); p.wait(timeout=5)"
    reply = execute("operator", "python3", "-c", script, data=framed).stdout
    assert reply == b"OK 0\n", reply
    accepted(fragmented)
    edited = fragmented
    passed("fragmented byte-counted nc stream is accepted without truncation")

    # Wrong prefix is valid configuration but must not establish a candidate.
    wrong = draft(prefix="wrong-secret", control_port=8100)
    with concurrent.futures.ThreadPoolExecutor() as pool:
        submission = pool.submit(put, wrong)
        await_pending(wrong)
        assert submission.result(timeout=15) == b"PENDING confirmation-required\n"
    assert remote(b"STATUS\n", port=8100, timeout=3) == b"", "wrong path-prefix established candidate"
    assert put(wrong) == b"PENDING confirmation-required\n", "old path incorrectly confirmed candidate"
    assert read("/etc/wtctl/active.ini") == edited
    eventually(lambda: read("/tmp/wtctl/activation") == b"failed confirmation-timeout\n",
               "wrong-prefix candidate timeout and rollback", seconds=100)
    assert get() == edited
    traffic()
    passed("server rejects wrong path prefix; old path cannot confirm; real deadline rolls back")

    candidate = draft(control_port=8100)
    assert put(candidate) == b"PENDING confirmation-required\n"
    await_pending(candidate)
    assert get(port=8099) == edited, "old management path lost despite distinct listener"
    superseding = edited + b"# superseding draft\n"
    # An old receiver submitting the same draft cannot confirm it; a genuinely
    # newer draft must invalidate that attempt and activate after rollback.
    reply = put(superseding, timeout=25)
    assert reply in (b"", b"OK 0\n"), reply
    eventually(lambda: get() == superseding, "superseding draft accepted after rollback")
    accepted(superseding)
    edited = superseding
    passed("newer remote draft supersedes candidate without concurrent replacement")

    maximum = edited + b"#" + b"x" * (65536 - len(edited) - 2) + b"\n"
    assert len(maximum) == 65536
    assert put(maximum) == b"OK 0\n"
    assert get() == maximum
    accepted(maximum)
    assert put(edited) == b"OK 0\n"
    passed("maximum 64 KiB configuration traverses nc and returns exact framed bytes")

    # Negative trust check: a valid INI can select a readable but untrusted CA.
    # It must fail reachability rather than silently disabling verification.
    device("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
           "-subj", "/CN=untrusted", "-keyout", "/tmp/untrusted.key", "-out", "/tmp/untrusted.pem")
    untrusted = draft(control_port=8100).replace(b"ca=/lab/ca.pem", b"ca=/tmp/untrusted.pem")
    assert put(untrusted) == b"PENDING confirmation-required\n"
    await_pending(untrusted)
    assert remote(b"STATUS\n", port=8100, timeout=3) == b"", "untrusted TLS established candidate"
    reply = put(edited, timeout=25)
    assert reply in (b"", b"OK 0\n"), reply
    eventually(lambda: get() == edited, "superseding untrusted candidate accepted")
    accepted(edited)
    passed("untrusted server CA cannot establish control; explicit superseding draft restores path")

    changed_port = draft(control_port=8100)
    eventually(lambda: read("/tmp/wtctl/activation") == b"idle\n",
               "superseding activation settled before port migration")
    reply = put(changed_port, timeout=25)
    assert reply == b"PENDING confirmation-required\n", (
        reply, read("/tmp/wtctl/activation"),
        shell("cat /tmp/wtctl/job.*/result /tmp/wtctl/job.*/log 2>/dev/null", check=False).stdout)
    await_pending(changed_port)
    confirm(changed_port, port=8100)
    accepted(changed_port)
    assert get(port=8100) == changed_port
    assert put(edited, port=8100) == b"PENDING confirmation-required\n"
    await_pending(edited)
    confirm(edited, port=8099)
    accepted(edited)
    passed("changed server-side control port is confirmed over candidate and can be migrated back")

    for key, changes in (
        ("manager", {"manager": "manager-v2"}),
        ("wstunnel", {"manager": "manager-v2", "binary": "binary-v2"}),
        ("both", {"manager": "manager-v3", "binary": "binary-v3"}),
    ):
        updated = draft(**changes)
        # Replacement can close the original TCP connection. STATUS/candidate
        # confirmation resolves the outcome; do not require its PENDING reply.
        with concurrent.futures.ThreadPoolExecutor() as pool:
            response = pool.submit(put, updated, 8099, 25)
            await_pending(updated)
            confirm(updated)
            response.result()
        accepted(updated)
        assert device("/usr/sbin/wtctl", "--version").stdout == (b"0.2.0-lab3\n" if key == "both" else b"0.2.0-lab2\n")
        assert read("/tmp/wtctl/bin/wstunnel") == read("/lab/" + changes.get("binary", "binary"))
        traffic()
        edited = updated
        passed(f"remote {key} URL update stages real downloads and confirms post-replacement WSS")

    for field, replacement in ((b"wstunnel_url=", b"https://sources:8443/missing"),
                               (b"url=", b"https://sources:8443/bad")):
        lines = edited.splitlines(keepends=True)
        failed = b"".join(field + replacement + b"\n" if line.startswith(field) else line for line in lines)
        reply = put(failed)
        assert reply.startswith(b"KO "), reply
        assert get("GET") == failed and get() == edited
        accepted(edited)
    passed("failed binary and manager downloads preserve accepted state and retain failed desired")

    accepted_before_invalid = get()
    desired_before_invalid = get("GET")
    assert put(b"[wtctl]\nformat=99\n").startswith(b"KO invalid-configuration")
    assert get() == accepted_before_invalid and get("GET") == desired_before_invalid
    passed("invalid remote INI changes neither desired nor active state")

    # Accepted RAM software must recover after runtime loss, not retry failed desired.
    failed_desired = get("GET")
    compose("restart", "device")
    eventually(lambda: get() == edited, "RAM recovery after container restart", seconds=120)
    assert get("GET") == failed_desired
    traffic()
    passed("container restart loses RAM, restores accepted binary and control, not failed desired")

    compose("stop", "wstunnel")
    # Restart only the failed service: `up` without --no-deps reruns init and
    # may recreate dependencies, mixing artifact provisioning into this outage.
    compose("up", "-d", "--no-deps", "--wait", "wstunnel")
    eventually(lambda: get() == edited, "server reconnection without resubmission", seconds=120)
    traffic()
    passed("server outage recovers accepted control and ordinary tunnels without confirmation")

    before_outage_requests = downloads()
    compose("stop", "sources")
    try:
        assert get() == edited
        traffic()
    finally:
        compose("up", "-d", "--no-deps", "--wait", "sources")
    assert downloads() == before_outage_requests
    passed("software-source outage does not disrupt accepted tunnels or force downloads")

    rollback = edited.replace(b"binary-v3", b"binary-v2").replace(b"manager-v3", b"manager-v2")
    old_binary = shell("sha256sum /tmp/wtctl/bin/wstunnel").stdout
    old_manager = read("/usr/sbin/wtctl")
    old_sources = read("/etc/wtctl/activation-state")
    with concurrent.futures.ThreadPoolExecutor() as pool:
        response = pool.submit(put, rollback, 8099, 25)
        await_pending(rollback)
        assert shell("sha256sum /tmp/wtctl/bin/wstunnel").stdout != old_binary
        assert read("/usr/sbin/wtctl") != old_manager
        eventually(lambda: read("/tmp/wtctl/activation") == b"failed confirmation-timeout\n",
                   "software replacement timeout restores accepted executable", seconds=110)
        response.result()
    assert get() == edited
    assert read("/etc/wtctl/activation-state") == old_sources
    assert shell("sha256sum /tmp/wtctl/bin/wstunnel").stdout == old_binary
    assert read("/usr/sbin/wtctl") == old_manager
    traffic()
    passed("unconfirmed software update rolls back software, source identities and all tunnels")

    persistent = edited.replace(b"storage=ram", b"storage=persistent")
    reply = put(persistent, timeout=25)
    assert reply in (b"", b"OK 0\n"), reply
    eventually(lambda: get() == persistent, "RAM-to-persistent activation after binary-path replacement")
    accepted(persistent)
    assert shell("test -x /etc/wtctl/bin/wstunnel").returncode == 0
    persistent_requests = downloads()
    compose("restart", "device")
    eventually(lambda: get() == persistent, "persistent software restart")
    assert downloads() == persistent_requests, "persistent restart unnecessarily downloaded software"
    traffic()
    passed("RAM-to-persistent transition and container recovery")

    reply = put(edited, timeout=25)
    assert reply in (b"", b"OK 0\n"), reply
    eventually(lambda: get() == edited, "persistent-to-RAM activation after binary-path replacement")
    accepted(edited)
    assert shell("test -x /tmp/wtctl/bin/wstunnel").returncode == 0
    traffic()
    passed("persistent-to-RAM transition uses real staged binary")

    no_tunnels = draft(manager="manager-v3", binary="binary-v3", storage="persistent", tunnels=False)
    reply = put(no_tunnels, timeout=25)
    assert reply in (b"", b"OK 0\n"), reply
    eventually(lambda: get() == no_tunnels, "control-only persistent activation")
    accepted(no_tunnels)
    assert get() == no_tunnels
    assert shell("test ! -d /tmp/wtctl/tunnels/ft").returncode == 0
    status = device("/usr/sbin/wtctl", "status").stdout
    assert b"Control:" in status and b"__control " not in status
    assert device("/usr/sbin/wtctl", "tunnel", "list").stdout == b""
    passed("omitted ordinary tunnels removed while control remains available")

    off = no_tunnels.replace(b"enabled=true", b"enabled=false")
    assert put(off) == b"OK 0\n", "disable removed its path before success reply"
    accepted(off)
    eventually(lambda: device("sh", "-c", "test ! -f /tmp/wtctl/receiver || ! kill -0 $(sed -n 's/^pid=//p' /tmp/wtctl/receiver)", check=False).returncode == 0,
               "receiver removal after disable")
    passed("remote disabling returns success before removing management connectivity")

    # Fresh bootstrap failures and retry semantics, not only failure on upgrades.
    reset_device()
    bad_first = draft(binary="missing")
    result = install(bad_first)
    assert result.returncode != 0 and b"KO download-failed" in result.stdout, (result.stdout, result.stderr)
    assert read("/etc/wtctl/desired.ini") == bad_first
    assert shell("test ! -f /etc/wtctl/active.ini").returncode == 0
    compose("restart", "device")
    assert shell("test ! -f /etc/wtctl/active.ini").returncode == 0
    result = install(initial)
    assert b"PENDING confirmation-required" in result.stdout, (result.stdout, result.stderr)
    await_pending(initial)
    eventually(lambda: read("/tmp/wtctl/activation") == b"failed confirmation-timeout\n",
               "first-install timeout restores bootstrap", seconds=100)
    assert shell("test ! -f /etc/wtctl/active.ini").returncode == 0
    assert read("/etc/wtctl/desired.ini") == initial
    assert local_apply(initial) == b"PENDING confirmation-required\n"
    confirm(initial)
    accepted(initial)
    passed("fresh download failure and confirmation timeout retain bootstrap; explicit retry succeeds")
    reset_device()
    matrix = device("sh", "/work/tests/compose/installer-adapters.sh", timeout=600)
    print(matrix.stdout.decode(), end="", flush=True)
    passed("new INI installer adapter matrix with explicit init/registration doubles")
    print(f"\n{CHECKS} Compose acceptance groups passed. Physical boot qualification is separate.", flush=True)


if __name__ == "__main__":
    main()
