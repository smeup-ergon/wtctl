"""Installer opt-in tests through a real PTY and unattended command lines.

Run only in the disposable fixture container after tests/startup.sh sets up
its OpenWrt/init-system shims. Never run against a host installation.
"""
import os
from pathlib import Path
import pty
import select
import subprocess
import time


def command(*args, success=True):
    result = subprocess.run(args, capture_output=True, timeout=20)
    assert (result.returncode == 0) == success, result.stderr.decode()
    return result.stdout


def interactive(answer):
    master, slave = pty.openpty()
    process = subprocess.Popen(['sh', '/work/scripts/install.sh', '--yes'],
                               stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    output = bytearray()
    prompt = b'Enable wtctl at boot using openwrt? [y/N] '
    try:
        deadline = time.monotonic() + 15
        while prompt not in output:
            assert time.monotonic() < deadline, 'installer did not offer boot autostart'
            ready, _, _ = select.select([master], [], [], 0.2)
            if ready:
                try:
                    data = os.read(master, 4096)
                except OSError:
                    data = b''
                assert data, 'installer exited without offering boot autostart'
                output.extend(data)
        os.write(master, answer.encode() + b'\n')
        assert process.wait(timeout=15) == 0, bytes(output)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        os.close(master)


def cleanup():
    if Path('/etc/init.d/wtctl').exists():
        command('/usr/sbin/wtctl', 'startup', 'remove', 'openwrt', '--yes')
    if Path('/usr/sbin/wtctl').exists():
        command('/usr/sbin/wtctl', 'uninstall', '--purge', '--yes')


try:
    interactive('')
    assert not Path('/etc/init.d/wtctl').exists(), 'default enabled startup without consent'
    assert b'Boot integration: not installed' in command('/usr/sbin/wtctl', 'doctor')
    cleanup()

    interactive('yes')
    assert b'Boot integration: openwrt' in command('/usr/sbin/wtctl', 'doctor')
    assert Path('/test/boot-enabled').exists()
    assert b'Supervisor: stopped' in command('/usr/sbin/wtctl', 'status'), 'installer started service now'
    original = Path('/etc/init.d/wtctl').read_bytes()
    command('/etc/init.d/wtctl', 'disable')
    interactive('y')
    assert Path('/test/boot-enabled').exists(), 'existing disabled adapter was not re-enabled'
    assert Path('/etc/init.d/wtctl').read_bytes() == original, 'existing adapter overwritten'
    interactive('n')
    assert Path('/test/boot-enabled').exists(), 'declining changed existing startup preference'
    cleanup()

    output = command('sh', '/work/scripts/install.sh', '--yes', '--startup', 'openwrt')
    assert b'[y/N]' not in output and Path('/test/boot-enabled').exists()
    command('sh', '/work/scripts/install.sh', '--yes', '--startup', 'openwrt')
    assert Path('/test/boot-enabled').exists(), 'explicit option is not idempotent'
    command('sh', '/work/scripts/install.sh', '--yes', '--no-startup')
    assert Path('/test/boot-enabled').exists(), '--no-startup disabled existing integration'
    cleanup()

    command('sh', '/work/scripts/install.sh', '--yes', '--no-startup', '--startup', 'openwrt', success=False)
    assert not Path('/usr/sbin/wtctl').exists(), 'invalid options modified installation'
    command('sh', '/work/scripts/install.sh', '--yes', '--startup', 'unsupported', success=False)
    assert not Path('/usr/sbin/wtctl').exists()
    command('sh', '/work/scripts/install.sh', '--yes', '--no-startup')
    assert not Path('/etc/init.d/wtctl').exists()
    command('/usr/sbin/wtctl', 'uninstall', '--purge', '--yes')
    print('Installer PTY consent/default/re-enable and unattended options passed.')
finally:
    cleanup()
