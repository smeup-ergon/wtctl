#!/usr/bin/env python3
"""Opt-in physical wtctl acceptance on an owner-approved disposable deployment.

Requires an authenticated SSH control socket, a MIPS static probe and a reachable
workstation LAN address. Refuses existing profiles/tunnels. No firewall/network,
firmware/feed, package or automatic reboot changes. Stops and restores the initial
wtctl configuration; peer/probe/CA are test-only. Passwords are never accepted as
arguments or written to artifacts. Reboots/power cycling are separate approval gates.
"""
import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--target", required=True)
parser.add_argument("--control-socket", required=True)
parser.add_argument("--host-ip", required=True)
parser.add_argument("--probe", type=Path, required=True)
parser.add_argument("--binary-url-file", type=Path, required=True, help="Private file containing the approved raw executable HTTPS URL")
parser.add_argument("--script", type=Path, default=Path(__file__).resolve().parent.parent / "wtctl")
parser.add_argument("--peer-image", default="wtctl-device-peer:local")
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--focus", choices=["restart-udp"], help="Minimal reverse-UDP supervisor-restart regression")
parser.add_argument("--focus-clients", type=int, choices=[1, 4], default=1)
parser.add_argument("--focus-idle-seconds", type=int, choices=[0, 40], default=0)
parser.add_argument("--focus-iterations", type=int, choices=[1, 3], default=3)
args = parser.parse_args()
if args.target.startswith("-"):
    parser.error("Invalid target")
host = str(ipaddress.IPv4Address(args.host_ip))
binary_url = args.binary_url_file.read_text().strip()
if not binary_url.startswith("https://") or "\n" in binary_url:
    parser.error("Supply an approved raw executable HTTPS URL")
q = shlex.quote
ssh_base = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2", "-S", args.control_socket, args.target]
nonce = secrets.token_hex(6)
prefix = secrets.token_hex(16)
remote = "/tmp/wtctl-device-" + nonce
container = "wtctl-device-" + nonce
ca = "/etc/wtctl/device-test-ca.pem"
ids = ["qa_rudp"] if args.focus and args.focus_clients == 1 else ["qa_ftcp", "qa_fudp", "qa_rtcp", "qa_rudp"]


class FocusComplete(Exception):
    pass
result = {"tests": [], "passed": False, "baseline_restored": False, "cleanup_errors": [], "reboot_performed": False, "wan_interface_modified": False, "failed_tests": []}
private = Path(tempfile.mkdtemp(prefix="wtctl-device-recovery."))
os.chmod(private, 0o700)
original = None
baseline_hashes = None
packages = None
started = False
modified = False
original_running = False
script = args.script.read_bytes()


def ssh(command, *, data=None, timeout=120):
    try:
        completed = subprocess.run(ssh_base + ["set -e;\n" + command], input=data, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise RuntimeError("SSH operation timed out (command/credentials suppressed)") from None
    if completed.returncode:
        detail = "unexpected-forwarded-payload" if b"unexpected forwarded payload" in completed.stderr else "socket-refused" if b"Connection refused" in completed.stderr else "config-lock-busy" if b"Busy: config" in completed.stderr else "command-failed"
        raise RuntimeError("SSH operation: " + detail + " (command/credentials suppressed)")
    return completed.stdout


def docker(*command, timeout=90):
    completed = subprocess.run(["docker", *command], capture_output=True, timeout=timeout)
    if completed.returncode:
        detail = "timeout" if b"TimeoutError" in completed.stderr else "payload-mismatch" if b"AssertionError" in completed.stderr else "command-failed"
        raise RuntimeError("Disposable peer operation: " + detail + " (command/environment suppressed)")
    return completed.stdout


def record(name, **metrics):
    row = {"name": name, **metrics}
    result["tests"].append(row)
    print("PASS " + json.dumps(row), flush=True)


def wait_for(callback, timeout=90):
    deadline = time.monotonic() + timeout
    while True:
        value = callback()
        if value:
            return value
        if time.monotonic() >= deadline:
            raise TimeoutError("Physical acceptance condition did not become true")
        time.sleep(1)


def control_hashes():
    return ssh("sha256sum /etc/config/network /etc/config/firewall /etc/config/system /etc/nginx/nginx.conf")


def state():
    text = ssh("""for file in /tmp/wtctl/tunnels/*/status; do
[ -f "$file" ] || continue
name=${file%/status}; name=${name##*/}
awk -F= -v name="$name" '$1=="state" {s=$2} $1=="pid" {p=$2} $1=="exit" {e=$2} $1=="restarts" {r=$2} END {printf "%s\\t%s\\t%s\\t%s\\t%s\\n",name,s,p,e,r}' "$file"
done""").decode()
    rows = {}
    for line in text.splitlines():
        name, status, pid, exit_code, restarts = line.split("\t")
        rows[name] = {"state": status, "pid": int(pid) if pid else None, "exit": exit_code, "restarts": int(restarts or 0)}
    return rows


def pids():
    return {name: row["pid"] for name, row in state().items() if row["state"] == "running" and row["pid"]}


def all_running():
    current = pids()
    return current if all(current.get(name) for name in ids) else None


def replaced_clients(previous):
    current = all_running()
    return current if current and all(current[name] != previous[name] for name in ids) else None


def manager_pid():
    return int(ssh("awk -F= '$1==\"pid\" {print $2}' /tmp/wtctl/daemon").strip())


def phase():
    return ssh("head -n 1 /tmp/wtctl/binary-status").decode().strip()


def probe(protocol, port, no_data=False):
    command = shlex.join([remote + "/net-probe", protocol, "127.0.0.1", str(port)])
    if no_data:
        command += " --expect-no-data"
    return json.loads(ssh(command, timeout=100))


def peer_udp_count():
    return int(docker("exec", container, "python3", "-c", "from pathlib import Path;p=Path('/evidence/udp-count');print(p.read_text() if p.exists() else '0')").strip())


def reverse_probe(protocol):
    before_count = peer_udp_count() if protocol == "udp" else None
    code = """
import json,socket,time
protocol=PROTOCOL
port=20003 if protocol=='tcp' else 20004
s=socket.socket(socket.AF_INET,socket.SOCK_STREAM if protocol=='tcp' else socket.SOCK_DGRAM)
s.settimeout(20)
s.connect(('127.0.0.1',port))
start=time.monotonic()
if protocol=='tcp':
    payload=bytes(range(256))*256
    for index in range(64):
        s.sendall(payload)
        data=bytearray()
        while len(data)<len(payload):
            block=s.recv(len(payload)-len(data))
            if not block: raise RuntimeError('EOF')
            data.extend(block)
        assert data==payload
    total=64*len(payload)
else:
    for index in range(16):
        payload=index.to_bytes(4,'big')+bytes(range(256))*4
        s.send(payload)
        assert s.recv(65536)==payload
    total=16*1028
s.close()
print(json.dumps({'bytes_echoed':total,'elapsed_seconds':time.monotonic()-start}))
""".replace("PROTOCOL", repr(protocol))
    try:
        measured = json.loads(docker("exec", container, "python3", "-c", code, timeout=100))
    except RuntimeError:
        if protocol == "udp":
            result["reverse_udp_failure"] = {"peer_echoed_datagrams": peer_udp_count() - before_count, "requested_datagrams": 16, "owned_client_state": state()}
        raise
    if protocol == "udp":
        measured["peer_echoed_datagrams"] = peer_udp_count() - before_count
    return measured


def record_reverse_udp(name):
    try:
        measured = reverse_probe("udp")
    except RuntimeError as error:
        if "timeout" not in str(error) and "payload-mismatch" not in str(error):
            raise
        row = {"name": name, "error": str(error), **result.get("reverse_udp_failure", {})}
        result["failed_tests"].append(row)
        print("FAIL " + json.dumps(row), flush=True)
        return False
    record(name, **measured)
    return True


def reverse_ready():
    try:
        docker("exec", container, "python3", "-c", "import socket;s=socket.create_connection(('127.0.0.1',20003),timeout=1);s.close()", timeout=10)
        return True
    except RuntimeError:
        return False


def traffic(label):
    wait_for(reverse_ready)
    for protocol, port in (("tcp", 20001), ("udp", 20002)):
        record(label + " forward " + protocol, **probe(protocol, port))
        if protocol == "udp":
            record_reverse_udp(label + " reverse udp")
        else:
            record(label + " reverse " + protocol, **reverse_probe(protocol))


def metrics():
    raw = ssh("""printf 'cpu '; awk '/^cpu / {n=0; for(i=2;i<=9;i++) n+=$i; print n}' /proc/stat
awk '/^MemAvailable:/ {print "available " $2}' /proc/meminfo
for meta in /tmp/wtctl/daemon /tmp/wtctl/tunnels/*/worker /tmp/wtctl/tunnels/*/child; do
[ -f "$meta" ] || continue
pid=$(awk -F= '$1=="pid" {print $2}' "$meta")
[ -r "/proc/$pid/stat" ] || continue
printf 'process %s ' "$pid"
awk '{sub(/^.*\\) /, ""); print $12+$13+$14+$15}' "/proc/$pid/stat"
awk -v pid="$pid" '/^VmRSS:/ {print "rss " pid " " $2}' "/proc/$pid/status"
[ ! -r "/proc/$pid/smaps_rollup" ] || awk -v pid="$pid" '/^Pss:/ {print "pss " pid " " $2}' "/proc/$pid/smaps_rollup"
done
printf 'flash '; df -Pk /overlay | awk 'END {print $4}'
printf 'tmp '; df -Pk /tmp | awk 'END {print $4}'""").decode()
    rows = {"process": {}, "rss": {}, "pss": {}}
    for line in raw.splitlines():
        fields = line.split()
        if fields[0] in ("process", "rss", "pss"):
            rows[fields[0]][fields[1]] = int(fields[2])
        else:
            rows[fields[0]] = int(fields[1])
    return rows


try:
    board = json.loads(ssh("ubus call system board"))
    result["device"] = {k: board[k] for k in ("model", "board_name", "kernel", "release")}
    result["script_sha256"] = hashlib.sha256(script).hexdigest()
    deployed_hash = ssh("sha256sum /usr/sbin/wtctl").decode().split()[0]
    assert deployed_hash == result["script_sha256"], "deployed script differs from candidate"
    ssh("wtctl doctor; test ! -e /etc/init.d/wtctl; test -x /tmp/wtctl-legacy/wstunnel; test -z \"$(ls -A /etc/wtctl/servers)\"; test -z \"$(ls -A /etc/wtctl/tunnels)\"")
    original_running = b"Supervisor: running" in ssh("wtctl status")
    original = ssh("tar -czf - /etc/wtctl")
    (private / "configuration.tar.gz").write_bytes(original)
    os.chmod(private / "configuration.tar.gz", 0o600)
    baseline_hashes = control_hashes()
    packages = ssh("opkg list-installed")
    for name, content in (("control-hashes", baseline_hashes), ("packages", packages)):
        (private / name).write_bytes(content)
        os.chmod(private / name, 0o600)
    ssh("! netstat -lnt | grep -Eq '127\\.0\\.0\\.1:(20001|20011)[[:space:]]'; ! netstat -lnu | grep -Eq '127\\.0\\.0\\.1:20002[[:space:]]'")
    record("Preflight: exact candidate, empty deployment, dependencies and private baseline captured")

    docker("run", "-d", "--platform", "linux/amd64", "--name", container, "-e", "TEST_HOST_IP=" + host, "-e", "TEST_PREFIX=" + prefix, "-p", host + ":24443:24443/tcp", "-p", host + ":20001:20001/tcp", "-p", host + ":20002:20002/udp", args.peer_image)
    started = True
    def peer_certificate():
        try:
            return docker("exec", container, "python3", "-c", "from pathlib import Path;print(Path('/evidence/ca.pem').read_text(),end='')", timeout=10)
        except RuntimeError:
            return None
    certificate = wait_for(peer_certificate)
    modified = True
    ssh("umask 077; mkdir " + q(remote) + "; dd of=" + q(remote + "/net-probe") + " 2>/dev/null; chmod 700 " + q(remote + "/net-probe"), data=args.probe.read_bytes())
    ssh("umask 077; dd of=" + q(ca) + " 2>/dev/null", data=certificate)
    ssh("umask 077; dd of=" + q(remote + "/wtctl") + " 2>/dev/null; chmod 700 " + q(remote + "/wtctl"), data=script)
    ssh("wtctl server add qa_peer --endpoint " + q(f"wss://{host}:24443") + " --auth path --prefix " + q(prefix) + " --ca " + q(ca))
    for name, direction, protocol, listen, target in (
        ("qa_ftcp", "forward", "tcp", 20001, "127.0.0.1"),
        ("qa_fudp", "forward", "udp", 20002, "127.0.0.1"),
        ("qa_rtcp", "reverse", "tcp", 20003, host),
        ("qa_rudp", "reverse", "udp", 20004, host),
    ):
        if name not in ids:
            continue
        target_port = 20001 if protocol == "tcp" else 20002
        ssh(shlex.join(["wtctl", "tunnel", "add", name, "--server", "qa_peer", "--direction", direction, "--protocol", protocol, "--listen", str(listen), "--target", target, "--port", str(target_port)]) + "; wtctl enable " + name)
    ssh("wtctl apply; wtctl startup install openwrt --yes; /etc/init.d/wtctl start")
    initial_pids = wait_for(all_running, timeout=120)
    assert ssh("ubus call service list '{\"name\":\"wtctl\"}' | jsonfilter -e '@.wtctl.instances.*.pid'").strip() == str(manager_pid()).encode()
    record("Native MIPS supervisor owned by OpenWrt procd", clients=len(ids))
    if args.focus:
        time.sleep(5)
        record("Minimal initial reverse-UDP traffic", **reverse_probe("udp"))
        for iteration in range(args.focus_iterations):
            before = manager_pid()
            previous_clients = pids()
            if args.focus_idle_seconds:
                ssh("wtctl stop all")
                wait_for(lambda: not pids())
                time.sleep(args.focus_idle_seconds)
            ssh("kill -KILL " + str(before))
            wait_for(lambda: manager_pid() != before)
            wait_for(lambda: replaced_clients(previous_clients), timeout=150)
            record("Minimal reverse-UDP immediately after supervisor restart", iteration=iteration + 1, **reverse_probe("udp"))
        result["passed"] = True
        raise FocusComplete
    traffic("Initial verified-WSS")

    first = metrics()
    time.sleep(20)
    second = metrics()
    assert second["available"] > 4096, "insufficient available memory"
    common = first["process"].keys() & second["process"].keys()
    ticks = sum(second["process"][p] - first["process"][p] for p in common)
    cpu_percent = 100 * ticks / (second["cpu"] - first["cpu"])
    record("20-second four-tunnel resource sample", aggregate_cpu_percent=round(cpu_percent, 2), rss_sum_kib=sum(second["rss"].values()), pss_sum_kib=sum(second["pss"].values()) if second["pss"] else None, mem_available_kib=second["available"], overlay_free_kib=second["flash"], tmp_free_kib=second["tmp"], note="RSS double-counts shared pages; short sample is not sustained-load qualification")

    ssh("wtctl tunnel edit qa_ftcp --listen 20011")
    time.sleep(5)
    assert pids()[ids[0]] == initial_pids[ids[0]], "draft edit applied prematurely"
    ssh("wtctl apply")
    changed = wait_for(lambda: all_running() if pids().get(ids[0]) != initial_pids[ids[0]] else None)
    assert all(changed[name] == initial_pids[name] for name in ids[1:]), "unaffected tunnels restarted"
    probe("tcp", 20011)
    ssh("wtctl tunnel edit qa_ftcp --listen 20001; wtctl apply")
    wait_for(all_running)
    record("Explicit apply changes only affected native client")

    ssh("wtctl stop qa_ftcp; wtctl apply")
    wait_for(lambda: not pids().get(ids[0]))
    ssh("wtctl start qa_ftcp")
    wait_for(all_running)
    ssh("wtctl disable qa_ftcp; wtctl apply")
    wait_for(lambda: not pids().get(ids[0]))
    ssh("wtctl enable qa_ftcp; wtctl apply")
    wait_for(all_running)
    record("Temporary stop/start and persistent disable/enable semantics")

    before = pids()
    ssh("kill -TERM " + str(before[ids[0]]))
    after = wait_for(lambda: all_running() if pids().get(ids[0]) != before[ids[0]] else None)
    assert all(after[name] == before[name] for name in ids[1:])
    assert state()[ids[0]]["restarts"] >= 1
    record("Independent child failure recovery; siblings preserved")

    before = manager_pid()
    previous_clients = pids()
    ssh("kill -KILL " + str(before))
    wait_for(lambda: manager_pid() != before)
    wait_for(lambda: replaced_clients(previous_clients), timeout=150)
    record("Real procd respawn and owned orphan reconciliation after supervisor SIGKILL")
    record("TCP traffic restored after supervisor crash", **probe("tcp", 20001))
    record_reverse_udp("Reverse UDP after supervisor crash")

    generation = docker("exec", container, "python3", "-c", "from pathlib import Path; print(Path('/evidence/generation').read_text())").strip()
    docker("kill", "--signal=HUP", container)
    wait_for(lambda: docker("exec", container, "python3", "-c", "from pathlib import Path; print(Path('/evidence/generation').read_text())").strip() != generation)
    time.sleep(8)
    probe("tcp", 20001)
    wait_for(reverse_ready, timeout=120)
    record_reverse_udp("Reverse UDP after peer restart")
    record("TCP peer reconnect restores traffic (not a WAN-outage test)")

    previous_clients = pids()
    ssh("wtctl server edit qa_peer --ca ''; wtctl apply")
    wait_for(lambda: replaced_clients(previous_clients))
    blocked = probe("tcp", 20001, no_data=True)
    assert blocked["connected"] and blocked["bytes_received"] == 0
    previous_clients = pids()
    ssh("wtctl server edit qa_peer --ca " + q(ca) + "; wtctl apply")
    wait_for(lambda: replaced_clients(previous_clients))
    probe("tcp", 20001)
    record("Untrusted test CA blocks payload; verified custom CA restores traffic")

    terminal = subprocess.run(ssh_base[:-1] + ["-tt", args.target, "wtctl menu"], input=b"1\n0\n", capture_output=True, timeout=120)
    assert terminal.returncode == 0 and b"1 Status" in terminal.stdout and b"Process state only" in terminal.stdout
    assert prefix.encode() not in terminal.stdout
    record("Physical SSH pseudo-terminal menu and redacted status")

    previous_clients = pids()
    ssh("wtctl binary configure ram " + q(binary_url) + "; wtctl apply")
    wait_for(lambda: replaced_clients(previous_clients) if phase() == "ready" else None, timeout=360)
    ssh("test -x /tmp/wtctl/bin/wstunnel")
    record("Native raw executable restored through verified HTTPS into RAM")
    record("TCP traffic after real binary download/activation", **probe("tcp", 20001))
    record_reverse_udp("Reverse UDP after real binary download/activation")

    # Persistent storage cannot accommodate the native executable on this overlay.
    ssh("wtctl binary configure persistent " + q(binary_url) + "; wtctl apply")
    wait_for(lambda: phase() == "insufficient-space")
    ssh("test ! -e /etc/wtctl/bin/wstunnel; test ! -e /etc/wtctl/bin/wstunnel.part")
    ssh("wtctl stop all; wtctl binary configure ram " + q(binary_url) + "; wtctl apply; wtctl start all")
    wait_for(all_running)
    record("Constrained-flash persistent download fails safely without a partial executable")

    bad_url = f"https://{host}:24443/unavailable-binary"
    ssh("wtctl binary configure ram " + q(bad_url) + "; wtctl apply; wtctl binary update --yes")
    wait_for(lambda: phase() == "download-failed")
    ssh("test ! -e /tmp/wtctl/bin/wstunnel")
    wait_for(lambda: not pids())
    deadline = int(ssh("head -n 1 /tmp/wtctl/next-download").strip())
    now = int(ssh("date +%s").strip())
    if deadline <= now:
        deadline = wait_for(lambda: int(ssh("head -n 1 /tmp/wtctl/next-download").strip()) or None)
    record("Destructive update removes native binary and schedules recovery", retry_epoch=deadline)
    ssh("wtctl stop all")
    wait_for(lambda: int(ssh("head -n 1 /tmp/wtctl/next-download").strip()) == 0)
    record("Explicit stop cancels physical download recovery")
    ssh("wtctl binary configure ram " + q(binary_url) + "; wtctl apply; wtctl start all")
    wait_for(lambda: phase() == "ready", timeout=360)
    wait_for(all_running)
    traffic("Recovered native RAM binary")

    # Exercise safe uninstall while keeping the original local executable intact.
    ssh("wtctl startup remove openwrt --yes; wtctl uninstall --yes; test ! -e /usr/sbin/wtctl; test ! -e /tmp/wtctl; test -f /etc/wtctl/global; test -x /tmp/wtctl-legacy/wstunnel")
    record("Physical uninstall stops owned processes and preserves config/external executable")
    ssh("cp " + q(remote + "/wtctl") + " /usr/sbin/wtctl; chmod 755 /usr/sbin/wtctl")
    assert ssh("sha256sum /usr/sbin/wtctl").decode().split()[0] == result["script_sha256"]
    record("Exact candidate reinstalled after uninstall test")
    assert control_hashes() == baseline_hashes and ssh("opkg list-installed") == packages
    assert ssh("curl -s -o /dev/null --max-time 10 -w '%{http_code}' http://127.0.0.1/").strip() == b"200"
    record("Vendor panel and network/firewall/system/nginx/package baseline preserved")
    result["passed"] = not result["failed_tests"]
except FocusComplete:
    pass
except Exception as error:
    result["error"] = str(error)
    print("FAIL " + str(error), flush=True)
finally:
    if original is not None and modified:
        cleanup_stage = "remove-startup"
        try:
            ssh("if [ -f /etc/init.d/wtctl ]; then wtctl startup remove openwrt --yes; fi")
            cleanup_stage = "shutdown"
            ssh("if [ -x /usr/sbin/wtctl ]; then wtctl shutdown; fi")
            cleanup_stage = "upload-private-baseline"
            ssh("umask 077; dd of=" + q(remote + "/configuration.tar.gz") + " 2>/dev/null", data=original)
            cleanup_stage = "restore-private-baseline"
            ssh("set -e; rm -rf /etc/wtctl; tar -xzf " + q(remote + "/configuration.tar.gz") + " -C /; cp " + q(remote + "/wtctl") + " /usr/sbin/wtctl; chmod 755 /usr/sbin/wtctl")
            if original_running:
                ssh("wtctl daemon --background")
            else:
                ssh("wtctl shutdown")
            cleanup_stage = "verify-baseline"
            assert control_hashes() == baseline_hashes and ssh("opkg list-installed") == packages
            # Compare the restored snapshot bytes, not nondeterministic tar metadata.
            restored = ssh("tar -czf - /etc/wtctl")
            import io
            import tarfile
            def contents(data):
                with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
                    return {row.name: archive.extractfile(row).read() for row in archive.getmembers() if row.isfile()}
            assert contents(restored) == contents(original)
            ssh("rm -rf " + q(remote))
            result["baseline_restored"] = True
        except Exception:
            result["cleanup_errors"].append("Device cleanup/restoration failed at " + cleanup_stage + "; use private recovery archive")
    if started:
        try:
            docker("rm", "-f", container)
        except Exception:
            result["cleanup_errors"].append("Disposable peer cleanup failed")
    if result["baseline_restored"] or original is None:
        import shutil
        shutil.rmtree(private)
    else:
        result["private_recovery_directory"] = str(private)
    result["passed"] = result["passed"] and not result["cleanup_errors"] and result["baseline_restored"]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print("Result: " + str(args.output), flush=True)
    if not result["passed"]:
        raise SystemExit(1)
