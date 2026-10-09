#!/usr/bin/env python3
"""Owner-approved download-cancellation test and final empty-device setup.

Requires --yes, a preinstalled wtctl and no profiles/tunnels/startup adapter.
Leaves RAM storage and OpenWrt boot startup enabled, with no tunnels configured.
No network/firewall/package/reboot changes. Authentication uses an existing SSH
control socket; URLs come from a private file, never result artifacts.
"""
import argparse
import json
from pathlib import Path
import shlex
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--target", required=True)
parser.add_argument("--control-socket", required=True)
parser.add_argument("--binary-url-file", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--yes", action="store_true", required=True)
args = parser.parse_args()
if args.target.startswith("-"):
    parser.error("Invalid target")
url = args.binary_url_file.read_text().strip()
if not url.startswith("https://") or "\n" in url:
    parser.error("Expected an approved raw executable HTTPS URL")
base = ["ssh", "-S", args.control_socket, "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=5", args.target]
result = {"tests": [], "passed": False, "reboot_performed": False, "wan_interface_modified": False}


def ssh(command, timeout=120):
    completed = subprocess.run(base + ["set -e;\n" + command], capture_output=True, timeout=timeout)
    if completed.returncode:
        raise RuntimeError("SSH operation failed (command/credentials suppressed)")
    return completed.stdout


def record(name, **metrics):
    row = {"name": name, **metrics}
    result["tests"].append(row)
    print("PASS " + json.dumps(row), flush=True)


def wait_for(callback, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        measured = callback()
        if measured:
            return measured
        time.sleep(0.5)
    raise TimeoutError("Physical download acceptance condition timed out")


try:
    ssh("test ! -e /etc/init.d/wtctl; test -z \"$(ls -A /etc/wtctl/servers)\"; test -z \"$(ls -A /etc/wtctl/tunnels)\"; wtctl shutdown")
    before = ssh("sha256sum /etc/config/network /etc/config/firewall /etc/config/system /etc/nginx/nginx.conf")
    ssh("wtctl binary configure ram " + shlex.quote(url) + "; wtctl apply; wtctl startup install openwrt --yes; /etc/init.d/wtctl start")
    record("Empty device configured for RAM binaries and OpenWrt procd startup")
    # Explicit install is destructive, matching the selected product policy.
    ssh("wtctl binary install --yes")
    def active_download():
        raw = ssh("""if [ -f /tmp/wtctl/download-child ]; then
pid=$(awk -F= '$1=="pid" {print $2}' /tmp/wtctl/download-child)
token=$(awk -F= '$1=="token" {print $2}' /tmp/wtctl/download-child)
if [ -r "/proc/$pid/stat" ]; then
current=$(awk '{sub(/^.*\\) /, ""); print $20}' "/proc/$pid/stat")
state=$(awk '{sub(/^.*\\) /, ""); print $1}' "/proc/$pid/stat")
[ "$current" != "$token" ] || [ "$state" = Z ] || printf '%s %s' "$pid" "$token"
fi
fi""").decode().split()
        return tuple(raw) if raw else None
    pid, token = wait_for(active_download, 90)
    ssh("wtctl stop all")
    def stopped():
        checked = ssh("""pid=PID; expected=TOKEN
alive=0
if [ -r "/proc/$pid/stat" ]; then
current=$(awk '{sub(/^.*\\) /, ""); print $20}' "/proc/$pid/stat")
state=$(awk '{sub(/^.*\\) /, ""); print $1}' "/proc/$pid/stat")
[ "$current" != "$expected" ] || [ "$state" = Z ] || alive=1
fi
if [ "$alive" = 0 ] && [ ! -e /tmp/wtctl/bin/wstunnel.part ]; then printf stopped; fi
""".replace("PID", pid).replace("TOKEN", token))
        return checked.strip() == b"stopped"
    wait_for(stopped, 30)
    wait_for(lambda: ssh("head -n 1 /tmp/wtctl/next-download").strip() == b"0", 30)
    record("Stop-all interrupts an observed live curl process, removes partial data and cancels retries")
    ssh("wtctl binary install --yes")
    wait_for(lambda: ssh("if [ -x /tmp/wtctl/bin/wstunnel ]; then head -n 1 /tmp/wtctl/binary-status; fi").strip().startswith(b"ready"), 360)
    version = ssh("/tmp/wtctl/bin/wstunnel --version").decode().strip()
    record("Manual install downloads and validates native executable without enabled tunnels", binary_version=version)
    assert ssh("sha256sum /etc/config/network /etc/config/firewall /etc/config/system /etc/nginx/nginx.conf") == before
    assert ssh("curl -s -o /dev/null --max-time 10 -w '%{http_code}' http://127.0.0.1/").strip() == b"200"
    ssh("/etc/init.d/wtctl enabled; test -z \"$(ls -A /etc/wtctl/servers)\"; test -z \"$(ls -A /etc/wtctl/tunnels)\"")
    record("Boot registration enabled; no fixture tunnels; vendor panel and core configuration preserved")
    result["passed"] = True
except Exception as error:
    result["error"] = str(error)
    # Avoid further destructive cleanup here; keep the installed manager for
    # owner/agent recovery, and report the exact bounded test stage instead.
    print("FAIL " + str(error), flush=True)
finally:
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print("Result: " + str(args.output), flush=True)
    if not result["passed"]:
        raise SystemExit(1)
