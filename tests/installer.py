"""Unified setup tests. Disposable fixture container ONLY, with init shims."""
from pathlib import Path
import os
import pty
import select
import subprocess
import termios
import time

INSTALL = ['sh', '/work/scripts/install.sh', '--yes']
URL = 'https://localhost:18888/binary'


def command(*args, success=True):
    result = subprocess.run(args, capture_output=True, timeout=90)
    assert (result.returncode == 0) == success, (result.stdout.decode(), result.stderr.decode())
    return result.stdout


def cleanup():
    if Path('/etc/init.d/wtctl').exists():
        command('/usr/sbin/wtctl', 'startup', 'remove', 'openwrt', '--yes')
    if Path('/usr/sbin/wtctl').exists():
        command('/usr/sbin/wtctl', 'uninstall', '--purge', '--yes')


def interactive():
    master, slave = pty.openpty()
    original = termios.tcgetattr(slave)
    process = subprocess.Popen(INSTALL, stdin=slave, stdout=slave, stderr=slave)
    pending = bytearray()
    try:
        for prompt, value in [(b'0 Cancel\r\n> ', b'1'),
                              (b'HTTPS raw binary URL (empty to keep current): ', URL.encode() + b'\n')]:
            deadline = time.monotonic() + 20
            while prompt not in pending:
                assert time.monotonic() < deadline, bytes(pending)
                ready, _, _ = select.select([master], [], [], .2)
                if ready:
                    data = os.read(master, 4096)
                    assert data
                    pending.extend(data)
            del pending[:pending.index(prompt) + len(prompt)]
            os.write(master, value)
        # Drain output while waiting to avoid PTY buffer deadlocks.
        deadline = time.monotonic() + 90
        while process.poll() is None:
            assert time.monotonic() < deadline, bytes(pending)
            ready, _, _ = select.select([master], [], [], .2)
            if ready:
                try:
                    pending.extend(os.read(master, 4096))
                except OSError:
                    break
        assert process.wait(timeout=10) == 0, bytes(pending)
        assert termios.tcgetattr(slave) == original
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=10)
        os.close(master)
        os.close(slave)


try:
    interactive()
    assert Path('/test/boot-enabled').exists()
    assert Path('/tmp/wtctl/bin/wstunnel').exists()
    assert b'Supervisor: running' in command('/usr/sbin/wtctl', 'status')
    command('/usr/sbin/wtctl', 'server', 'add', 'keep', '--endpoint', 'wss://example.com')
    command('/usr/sbin/wtctl', 'tunnel', 'add', 'keep', '--server', 'keep', '--listen', '19333', '--target', 'localhost', '--port', '80')
    original = Path('/etc/init.d/wtctl').read_bytes()
    command('/etc/init.d/wtctl', 'disable')
    command(*INSTALL)
    assert Path('/test/boot-enabled').exists(), 'rerun did not ensure boot startup'
    assert Path('/etc/init.d/wtctl').read_bytes() == original
    assert Path('/etc/wtctl/tunnels/keep').exists(), 'rerun lost tunnels'
    assert b'keep' in command('/usr/sbin/wtctl', 'status')
    old_binary = Path('/tmp/wtctl/bin/wstunnel').read_bytes()
    old_global = Path('/etc/wtctl/global').read_bytes()
    old_script = Path('/usr/sbin/wtctl').read_bytes()
    command(*INSTALL, '--url', 'https://localhost:18888/bad', success=False)
    assert Path('/tmp/wtctl/bin/wstunnel').read_bytes() == old_binary
    assert Path('/etc/wtctl/global').read_bytes() == old_global
    assert Path('/usr/sbin/wtctl').read_bytes() == old_script
    assert b'Supervisor: running' in command('/usr/sbin/wtctl', 'status')
    command(*INSTALL, '--url', URL, '--storage', 'persistent')
    assert Path('/etc/wtctl/bin/wstunnel').exists()
    assert Path('/etc/wtctl/tunnels/keep').exists()
    cleanup()
    command(*INSTALL, '--startup', 'unsupported', success=False)
    command(*INSTALL, '--no-startup', success=False)
    assert not Path('/usr/sbin/wtctl').exists()
    command(*INSTALL, '--url', URL, '--storage', 'ram', '--startup', 'openwrt')
    assert Path('/test/boot-enabled').exists()
    assert b'Supervisor: running' in command('/usr/sbin/wtctl', 'status')
    print('Unified setup PTY/unattended, boot/start, rerun preservation, update rollback passed.')
finally:
    cleanup()
