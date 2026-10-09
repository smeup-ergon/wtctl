"""Disposable, restricted WSS/echo peer for physical wtctl testing.

Adapted from edge-net-devices test tooling. No production targets are permitted.
"""
import ipaddress
import os
from pathlib import Path
import signal
import socketserver
import subprocess
import tempfile
import threading
import time

host = str(ipaddress.IPv4Address(os.environ["TEST_HOST_IP"]))
prefix = os.environ["TEST_PREFIX"]
if not prefix.isalnum():
    raise ValueError("Invalid test prefix")


class TCP(socketserver.BaseRequestHandler):
    def handle(self):
        while data := self.request.recv(65536):
            self.request.sendall(data)


udp_count = 0
udp_lock = threading.Lock()


class UDP(socketserver.BaseRequestHandler):
    def handle(self):
        global udp_count
        data, sock = self.request
        with udp_lock:
            udp_count += 1
            Path("/evidence/udp-count").write_text(str(udp_count))
        sock.sendto(data, self.client_address)


class TCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


servers = [TCPServer(("0.0.0.0", 20001), TCP), socketserver.ThreadingUDPServer(("0.0.0.0", 20002), UDP)]
for server in servers:
    threading.Thread(target=server.serve_forever, daemon=True).start()
restart = threading.Event()
stopping = threading.Event()
signal.signal(signal.SIGHUP, lambda *_: restart.set())
signal.signal(signal.SIGTERM, lambda *_: stopping.set())

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    ca, ca_key = root / "ca.pem", root / "ca-key.pem"
    cert, key, csr = root / "server.pem", root / "server-key.pem", root / "server.csr"
    extensions = root / "extensions.cnf"
    extensions.write_text(f"subjectAltName=IP:{host}\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n")
    commands = [
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(ca_key), "-out", str(ca), "-days", "1", "-subj", "/CN=wtctl disposable test CA", "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign"],
        ["openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", str(key), "-out", str(csr), "-subj", "/CN=wtctl disposable peer"],
        ["openssl", "x509", "-req", "-in", str(csr), "-CA", str(ca), "-CAkey", str(ca_key), "-CAcreateserial", "-out", str(cert), "-days", "1", "-extfile", str(extensions)],
    ]
    for command in commands:
        subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    Path("/evidence/ca.pem").write_bytes(ca.read_bytes())
    restrictions = root / "restrictions.yaml"
    restrictions.write_text(
        "restrictions:\n  - name: 'Disposable echo only'\n    match:\n"
        f"      - !PathPrefix '^{prefix}$'\n    allow:\n"
        "      - !Tunnel\n        protocol: [Tcp, Udp]\n        port: [20001, 20002]\n        cidr: [127.0.0.1/32]\n"
        "      - !ReverseTunnel\n        protocol: [Tcp, Udp]\n        port: [20003, 20004]\n        cidr: [127.0.0.1/32]\n"
    )
    command = ["/real-wstunnel", "server", "--nb-worker-threads", "2", "--log-lvl", "OFF", "--tls-certificate", str(cert), "--tls-private-key", str(key), "--restrict-config", str(restrictions), "wss://0.0.0.0:24443"]
    generation = 0
    while not stopping.is_set():
        child = subprocess.Popen(command)
        generation += 1
        Path("/evidence/generation").write_text(str(generation))
        try:
            while child.poll() is None and not restart.is_set() and not stopping.is_set():
                time.sleep(0.1)
        finally:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        if not restart.is_set() and not stopping.is_set():
            raise RuntimeError("Test server exited unexpectedly")
        restart.clear()
        time.sleep(0.5)
