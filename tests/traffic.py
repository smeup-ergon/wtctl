"""Real wstunnel v11 traffic smoke test, isolated in a development container."""
import os
import pathlib
import socket
import subprocess
import threading
import time

ROOT = pathlib.Path("/test")
ROOT.mkdir(exist_ok=True)
os.environ.update(WTCTL_CONFIG_DIR="/test/config", WTCTL_STATE_DIR="/test/state")
W = "/work/wtctl"


def run(*args):
    subprocess.run([W, *args], check=True)


def openssl(*args):
    subprocess.run(["openssl", *args], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def echo_tcp():
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 17080))
    listener.listen()
    while True:
        conn, _ = listener.accept()
        with conn:
            conn.settimeout(3)
            try:
                conn.sendall(conn.recv(4096))
            except OSError:
                pass


def echo_udp():
    listener = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    listener.bind(("127.0.0.1", 17081))
    while True:
        data, peer = listener.recvfrom(4096)
        listener.sendto(data, peer)


def probe(protocol, port):
    payload = f"wtctl-{protocol}-{port}".encode()
    kind = socket.SOCK_STREAM if protocol == "tcp" else socket.SOCK_DGRAM
    last_error = None
    for _ in range(20):
        try:
            with socket.socket(socket.AF_INET, kind) as client:
                client.settimeout(2)
                client.connect(("127.0.0.1", port))
                client.sendall(payload)
                assert client.recv(4096) == payload, "incorrect echoed payload"
            return
        except (OSError, AssertionError) as error:
            last_error = error
            time.sleep(1)
    raise AssertionError(f"{protocol} port {port} failed: {last_error}")


openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "/test/ca.key", "-out", "/test/ca.pem", "-days", "1", "-subj", "/CN=wtctl-test-CA", "-addext", "basicConstraints=critical,CA:TRUE")
openssl("req", "-newkey", "rsa:2048", "-nodes", "-keyout", "/test/server.key", "-out", "/test/server.csr", "-subj", "/CN=localhost")
(ROOT / "extensions").write_text("subjectAltName=DNS:localhost\nbasicConstraints=critical,CA:FALSE\nextendedKeyUsage=serverAuth\n")
openssl("x509", "-req", "-in", "/test/server.csr", "-CA", "/test/ca.pem", "-CAkey", "/test/ca.key", "-CAcreateserial", "-out", "/test/server.pem", "-days", "1", "-extfile", "/test/extensions")
for target in (echo_tcp, echo_udp):
    threading.Thread(target=target, daemon=True).start()
server_log = open("/test/server.log", "wb")
server = subprocess.Popen(["/real-wstunnel", "server", "--nb-worker-threads", "1", "--tls-certificate", "/test/server.pem", "--tls-private-key", "/test/server.key", "--restrict-http-upgrade-path-prefix", "test-prefix", "wss://127.0.0.1:18443"], stdout=server_log, stderr=subprocess.STDOUT)
try:
    run("status")
    pathlib.Path('/test/state/bin').mkdir(parents=True, exist_ok=True)
    import shutil
    shutil.copy('/real-wstunnel', '/test/state/bin/wstunnel')
    run("_bootstrap", "https://example.com/manager")
    # Accept the already-provisioned test binary; this case tests real traffic
    # and control streams, not HTTPS download staging.
    (ROOT / "config/activation-state").write_text(
        "manager_url=https://example.com/manager\nwstunnel_url=https://example.com/binary\n"
    )
    base = (
        "[wtctl]\nformat=1\nurl=https://example.com/manager\n"
        "wstunnel_url=https://example.com/binary\n[control]\nENABLED"
        "server=peer\nbind=127.0.0.1\nlisten=18099\n"
        "[server peer]\nendpoint=wss://localhost:18443\n"
        "auth=path\nprefix=test-prefix\nca=/test/ca.pem\n"
    )
    for name, direction, protocol, listen, target in (
        ("ft", "forward", "tcp", 18001, 17080),
        ("fu", "forward", "udp", 18002, 17081),
        ("rt", "reverse", "tcp", 18003, 17080),
        ("ru", "reverse", "udp", 18004, 17081),
    ):
        base += (f"[tunnel {name}]\nserver=peer\ndirection={direction}\nprotocol={protocol}\n"
                 f"listen={listen}\ntarget=127.0.0.1\nport={target}\n")
    run("daemon", "--background")
    (ROOT / "tunnels.ini").write_text(base.replace("ENABLED", "enabled=false\n"))
    assert subprocess.check_output([W, "apply", "/test/tunnels.ini"]) == b"OK 0\n"
    for protocol, port in (("tcp", 18001), ("udp", 18002), ("tcp", 18003), ("udp", 18004)):
        probe(protocol, port)
        print(f"PASS: verified-TLS {protocol} traffic on {port}", flush=True)
    run("status")
    draft = base.replace("ENABLED", "").encode()
    (ROOT / "control.ini").write_bytes(draft)
    pending = subprocess.check_output([W, "apply", "/test/control.ini"])
    assert pending == b"PENDING confirmation-required\n", pending

    def control_request(payload):
        # Plain unauthenticated SSH session to the server-side forwarded port.
        result = subprocess.run(["dbclient", "-y", "-y", "-T", "-p", "18099", "wtctl@127.0.0.1", "x"],
                                input=payload, capture_output=True, timeout=60)
        return result.stdout

    for attempt in range(20):
        reply = control_request(f"PUT {len(draft)}\n".encode() + draft)
        if reply:
            break
        time.sleep(1)
    assert reply == b"OK 0\n", reply
    assert control_request(b"GET ACTIVE\n") == f"OK {len(draft)}\n".encode() + draft
    disabled = base.replace("ENABLED", "enabled=false\n").encode()
    assert control_request(f"PUT {len(disabled)}\n".encode() + disabled) == b"OK 0\n"
    print("PASS: real WSS control confirmation, GET ACTIVE, and remote disable reply", flush=True)
    print("4 ordinary traffic checks and control stream checks passed. Physical OpenWrt qualification is still required.", flush=True)
except Exception:
    run("status")
    server_log.flush()
    print((ROOT / "server.log").read_text(), flush=True)
    raise
finally:
    subprocess.run([W, "shutdown"], check=False)
    server.terminate()
    try:
        server.wait(timeout=10)
    except subprocess.TimeoutExpired:
        server.kill()
        server.wait()
    server_log.close()
