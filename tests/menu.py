"""Exercise the no-dialog interactive menu through a real pseudo-terminal."""
import os
import pty
import select
import subprocess
import time

master, slave = pty.openpty()
env = dict(os.environ, WTCTL_CONFIG_DIR="/test/menu-config", WTCTL_STATE_DIR="/test/menu-state")
process = subprocess.Popen(["/work/wtctl", "menu"], stdin=slave, stdout=slave, stderr=slave, env=env)
os.close(slave)
transcript = bytearray()


def answer(prompt, value):
    deadline = time.monotonic() + 15
    response = bytearray()
    while prompt.encode() not in response:
        if time.monotonic() > deadline:
            raise AssertionError(f"menu did not show {prompt!r}: {bytes(response)!r}")
        ready, _, _ = select.select([master], [], [], 0.5)
        if ready:
            data = os.read(master, 4096)
            assert data, "menu exited unexpectedly"
            response.extend(data)
            transcript.extend(data)
    os.write(master, value.encode() + b"\n")


try:
    answer("> ", "2")
    answer("Action (add/edit/remove/back): ", "add")
    answer("Server name: ", "demo")
    answer("WSS endpoint: ", "wss://example.com")
    answer("Authentication (none/path/basic) [none]: ", "basic")
    answer("Username: ", "user")
    answer("Password: ", "hidden-menu-password")
    answer("Custom CA file (empty for system trust): ", "")
    answer("Apply now? [y/N] ", "y")
    answer("> ", "2")
    answer("Action (add/edit/remove/back): ", "remove")
    answer("Server name: ", "demo")
    answer("Remove demo? [y/N] ", "y")
    answer("Apply now? [y/N] ", "y")
    answer("> ", "0")
    assert process.wait(timeout=10) == 0
    assert b"hidden-menu-password" not in transcript, "password echoed by menu"
    assert not os.path.exists("/test/menu-config/servers/demo"), "wrong record removed"
    print("Interactive menu/hidden password/removal checks passed.")
finally:
    if process.poll() is None:
        process.terminate()
        process.wait(timeout=10)
    os.close(master)
