"""Unified setup tests. Disposable fixture container ONLY, with init shims."""
from pathlib import Path
import os
import fcntl
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


def interactive(streamed=False, approve=True):
    master, slave = pty.openpty()
    original = termios.tcgetattr(slave)

    def controlling_terminal():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    args = INSTALL
    options = {}
    prompts = [(b'0 Cancel\r\n> ', b'1'),
               (b'HTTPS raw binary URL (empty to keep current): ', URL.encode() + b'\n')]
    if streamed:
        args = ['sh', '-c', 'cd /; curl -fsSL https://raw.githubusercontent.com/smeup-ergon/wtctl/main/scripts/install.sh | sh']
        options = {'env': bootstrap_env, 'preexec_fn': controlling_terminal}
        prompts.insert(0, (b'0 Cancel\r\n> ', b'1' if approve else b'0'))
        if not approve:
            prompts = prompts[:1]
    process = subprocess.Popen(args, stdin=slave, stdout=slave, stderr=slave, **options)
    pending = bytearray()
    try:
        for prompt, value in prompts:
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
        assert (process.wait(timeout=10) == 0) == approve, bytes(pending)
        assert termios.tcgetattr(slave) == original
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=10)
        os.close(master)
        os.close(slave)


# Keep bootstrap HTTP mocked while actual binary downloads use verified local TLS.
# This exercises streaming from an arbitrary cwd without downloading current main.
bootstrap_tools = Path('/test/bootstrap-tools')
bootstrap_tools.mkdir(exist_ok=True)
bootstrap_curl = bootstrap_tools / 'curl'
bootstrap_curl.write_text('''#!/bin/sh
set -eu
out=
previous=
source_url=
for arg do
    [ "$previous" != --output ] || out=$arg
    case "$arg" in https://raw.githubusercontent.com/smeup-ergon/wtctl/*) source_url=$arg;; esac
    previous=$arg
done
case "$source_url" in
    */scripts/install.sh) exec /bin/cat /work/scripts/install.sh;;
    */wtctl)
        printf '%s\\n' "$*" >> /test/bootstrap.calls
        case "${BOOTSTRAP_TEST_MODE:-}" in
            fail) exit 22;;
            invalid) printf 'not a manager\\n' > "$out";;
            syntax) printf '# wtctl: root-operated, POSIX-shell wstunnel client manager for Linux.\\nif\\n' > "$out";;
            *) cp /work/wtctl "$out";;
        esac;;
    *) exec /usr/bin/curl "$@";;
esac
''')
bootstrap_curl.chmod(0o755)
bootstrap_env = dict(os.environ, PATH=str(bootstrap_tools) + ':' + os.environ['PATH'])
installer_source = Path('/work/scripts/install.sh').read_bytes()


def streamed(*args, success=True, mode=''):
    env = dict(bootstrap_env, BOOTSTRAP_TEST_MODE=mode)
    result = subprocess.run(['sh', '-s', '--', *args], input=installer_source,
                            cwd='/', env=env, capture_output=True, timeout=90)
    assert (result.returncode == 0) == success, (result.stdout, result.stderr)
    return result


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
    cleanup()
    interactive(streamed=True, approve=False)
    assert not Path('/usr/sbin/wtctl').exists(), 'cancelled streamed setup installed manager'
    streamed(success=False)
    assert not Path('/usr/sbin/wtctl').exists(), 'unapproved unattended stream modified installation'
    # Truncation cannot run partially received installer actions.
    result = subprocess.run(['sh', '-s', '--', '--yes'], input=installer_source[:installer_source.index(b'TARGET=')],
                            cwd='/', env=bootstrap_env, capture_output=True, timeout=10)
    assert result.returncode != 0 and not Path('/usr/sbin/wtctl').exists()
    for mode in ('fail', 'invalid', 'syntax'):
        streamed('--yes', '--url', URL, success=False, mode=mode)
        assert not Path('/usr/sbin/wtctl').exists()
        assert not list(Path('/usr/sbin').glob('wtctl.new.*')), 'bootstrap left staging scripts'
    streamed('--yes', '--url', URL, '--ref', '../escape', success=False)
    interactive(streamed=True)
    assert Path('/test/boot-enabled').exists()
    assert b'Supervisor: running' in command('/usr/sbin/wtctl', 'status')
    command('/usr/sbin/wtctl', 'server', 'add', 'stream', '--endpoint', 'wss://example.com')
    command('/usr/sbin/wtctl', 'tunnel', 'add', 'stream', '--server', 'stream', '--listen', '19333', '--target', 'localhost', '--port', '80')
    old_script = Path('/usr/sbin/wtctl').read_bytes()
    old_global = Path('/etc/wtctl/global').read_bytes()
    for mode in ('fail', 'invalid', 'syntax'):
        streamed('--yes', '--url', URL, success=False, mode=mode)
        assert Path('/usr/sbin/wtctl').read_bytes() == old_script
        assert Path('/etc/wtctl/global').read_bytes() == old_global
        assert b'Supervisor: running' in command('/usr/sbin/wtctl', 'status')
    streamed('--yes', '--url', URL, '--storage', 'persistent', '--startup', 'openwrt', '--ref', 'test-pinned-ref')
    assert Path('/etc/wtctl/tunnels/stream').exists(), 'streamed update lost tunnels'
    assert Path('/etc/wtctl/bin/wstunnel').exists()
    calls = Path('/test/bootstrap.calls').read_text()
    assert 'https://raw.githubusercontent.com/smeup-ergon/wtctl/test-pinned-ref/wtctl' in calls
    assert "--proto =https --proto-redir =https" in calls
    print('Local and streamed setup, controlling-tty prompts, consent, pinned refs, bootstrap failure preservation and updates passed.')
finally:
    cleanup()
