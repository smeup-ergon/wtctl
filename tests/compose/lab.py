#!/usr/bin/env python3
"""Isolated Compose lab support: artifact initialization, HTTPS, TCP/UDP echo."""

import argparse
import http.server
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socketserver
import ssl
import subprocess
import threading
import time
from urllib.parse import urlsplit


LAB = Path("/lab")
EVENT_LOCK = threading.Lock()


def init():
    LAB.mkdir(parents=True, exist_ok=True)
    # Repeated `up` preserves the same CA until the named volume is removed.
    if not (LAB / "ca.pem").exists() or not (LAB / "server.pem").exists():
        subprocess.run(
            ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
             "-days", "7", "-subj", "/CN=wtctl isolated lab CA",
             "-addext", "basicConstraints=critical,CA:TRUE",
             "-keyout", str(LAB / "ca.key"), "-out", str(LAB / "ca.pem")],
            check=True,
        )
        subprocess.run(
            ["openssl", "req", "-newkey", "rsa:2048", "-nodes",
             "-subj", "/CN=wstunnel", "-keyout", str(LAB / "server.key"),
             "-out", str(LAB / "server.csr")], check=True,
        )
        extensions = LAB / "server.ext"
        extensions.write_text(
            "basicConstraints=critical,CA:FALSE\n"
            "keyUsage=critical,digitalSignature,keyEncipherment\n"
            "extendedKeyUsage=serverAuth\n"
            "subjectAltName=DNS:sources,DNS:wstunnel,DNS:localhost,IP:127.0.0.1\n"
        )
        subprocess.run(
            ["openssl", "x509", "-req", "-in", str(LAB / "server.csr"),
             "-CA", str(LAB / "ca.pem"), "-CAkey", str(LAB / "ca.key"),
             "-CAcreateserial", "-days", "7", "-extfile", str(extensions),
             "-out", str(LAB / "server.pem")], check=True,
        )
    # The official server runs as an unprivileged app user. These keys are
    # disposable lab credentials, never production credentials.
    for name in ("ca.pem", "server.pem", "server.key"):
        (LAB / name).chmod(0o644)
    (LAB / "ca.key").chmod(0o600)
    shutil.copyfile("/work/wtctl", LAB / "manager")
    shutil.copyfile("/opt/wstunnel-source", LAB / "binary")
    for name in ("manager", "binary"):
        (LAB / name).chmod(0o755)
    # Distinct manager payloads prove replacement/rollback changes bytes, rather
    # than only changing a URL while downloading an identical artifact.
    (LAB / "manager-v2").write_bytes((LAB / "manager").read_bytes().replace(b"VERSION=0.3.0\n", b"VERSION=0.3.0-lab2\n", 1))
    (LAB / "manager-v3").write_bytes((LAB / "manager").read_bytes().replace(b"VERSION=0.3.0\n", b"VERSION=0.3.0-lab3\n", 1))
    # Trailing markers do not change ELF loading or real tunnel behavior, but
    # make staged versions byte-distinct for replacement/rollback assertions.
    for version in (2, 3):
        (LAB / f"binary-v{version}").write_bytes((LAB / "binary").read_bytes() + f"\nwtctl-lab-version-{version}\n".encode())
    (LAB / "downloads.jsonl").touch()
    (LAB / "registration.log").touch()


class Sources(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        if urlsplit(self.path).path != "/health":
            super().log_message(format, *args)

    def do_GET(self):
        self.serve()

    def do_HEAD(self):
        self.serve(head=True)

    def serve(self, head=False):
        parsed = urlsplit(self.path)
        name = parsed.path.removeprefix("/")
        status = 200
        artifact = None
        if name == "health":
            payload = b"ok\n"
        elif name == "missing":
            status, payload = 503, b"artifact unavailable\n"
        elif name == "bad":
            payload = b"this is not a valid executable\n"
        elif name == "slow":
            # Bounded even when a client does not set a timeout.
            time.sleep(max(0, min(30, float(os.environ.get("LAB_SLOW_SECONDS", "5")))))
            artifact = LAB / "binary"
            payload = None
        elif re.fullmatch(r"(?:manager|binary)(?:-[A-Za-z0-9._-]+)?", name):
            artifact = LAB / name
            if not artifact.is_file():
                artifact = LAB / name.split("-", 1)[0]
            payload = None
        else:
            status, payload = 404, b"not found\n"
        # Record requests including failures, but not healthcheck noise. Query
        # strings never affect routing and remain available for assertions.
        if name != "health":
            event = {"time": time.time(), "method": self.command,
                     "path": parsed.path, "query": parsed.query,
                     "url": self.path, "status": status,
                     "artifact": artifact.name if artifact else None}
            with EVENT_LOCK:
                with (LAB / "downloads.jsonl").open("a") as log:
                    log.write(json.dumps(event) + "\n")
        length = artifact.stat().st_size if artifact else len(payload)
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(length))
            self.end_headers()
            if not head:
                if artifact:
                    with artifact.open("rb") as source:
                        shutil.copyfileobj(source, self.wfile)
                else:
                    self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass  # Timeout/failed-download scenarios intentionally disconnect.


def sources():
    server = http.server.ThreadingHTTPServer(("0.0.0.0", 8443), Sources)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(LAB / "server.pem", LAB / "server.key")
    server.socket = context.wrap_socket(server.socket, server_side=True)
    server.serve_forever()


class TCPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        while data := self.request.recv(65536):
            self.request.sendall(data)


class UDPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        sock.sendto(data, self.client_address)


class TCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


class UDPServer(socketserver.ThreadingUDPServer):
    allow_reuse_address = True
    daemon_threads = True


def echo():
    tcp = TCPServer(("0.0.0.0", 17080), TCPHandler)
    udp = UDPServer(("0.0.0.0", 17081), UDPHandler)
    for server in (tcp, udp):
        threading.Thread(target=server.serve_forever, daemon=True).start()
    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
    signal.pause()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("init", "sources", "echo"))
    args = parser.parse_args()
    {"init": init, "sources": sources, "echo": echo}[args.mode]()
