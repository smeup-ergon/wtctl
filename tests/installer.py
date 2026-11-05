"""No-parameter installer tests. Disposable fixture container ONLY, with init shims.

Runs after startup.sh has left OpenWrt rc.common and update-rc.d shims in place,
inside test.sh while its verified-TLS download fixture is still serving.
"""
from pathlib import Path
import os
import subprocess

INSTALL = ['sh', '/work/scripts/install.sh']
MAIN = 'https://raw.githubusercontent.com/smeup-ergon/wtctl/main/wtctl'
SAMPLE = Path('/etc/wtctl/wtctl.ini')
WTCTL = '/usr/sbin/wtctl'


def command(*args, success=True, env=None):
    result = subprocess.run(args, capture_output=True, timeout=120, env=env)
    assert (result.returncode == 0) == success, (args, result.stdout.decode(), result.stderr.decode())
    return result.stdout + result.stderr


def uninstall(purge=True):
    if Path(WTCTL).exists():
        command(WTCTL, 'uninstall', *(['--purge'] if purge else []), '--yes')
    assert not Path('/etc/init.d/wtctl').exists(), 'uninstall left boot integration'


def field(path, key):
    for line in Path(path).read_text().splitlines():
        if line.startswith(key + '='):
            return line[len(key) + 1:]
    return None


# Keep bootstrap HTTP mocked; the streamed installer never reaches GitHub.
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
    '') exec /usr/bin/curl "$@";;
    */wtctl)
        printf '%s\\n' "$*" >> /test/bootstrap.calls
        case "${BOOTSTRAP_TEST_MODE:-}" in
            fail) exit 22;;
            invalid) printf 'not a manager\\n' > "$out";;
            syntax) printf '# wtctl: root-operated, POSIX-shell wstunnel client manager for Linux.\\nif\\n' > "$out";;
            *) cp /work/wtctl "$out";;
        esac;;
    *) exit 22;;
esac
''')
bootstrap_curl.chmod(0o755)
bootstrap_env = dict(os.environ, PATH=str(bootstrap_tools) + ':' + os.environ['PATH'])
installer_source = Path('/work/scripts/install.sh').read_bytes()


def streamed(success=True, mode='', source=installer_source):
    env = dict(bootstrap_env, BOOTSTRAP_TEST_MODE=mode)
    result = subprocess.run(['sh', '-s'], input=source, cwd='/', env=env, capture_output=True, timeout=120)
    assert (result.returncode == 0) == success, (result.stdout, result.stderr)
    return result


try:
    assert not Path(WTCTL).exists()
    for args in (['--yes'], ['--config', '/dev/null'], ['--url', 'https://example.com/x']):
        command(*INSTALL, *args, success=False)
    assert not Path(WTCTL).exists(), 'parameters were accepted'

    # No detectable init system: refuse before changing anything.
    hidden = [Path('/etc/openwrt_release'), Path('/usr/bin/update-rc.d')]
    for path in hidden:
        path.rename(str(path) + '.hidden')
    try:
        output = command(*INSTALL, success=False)
        assert b'No supported init system' in output, output
        assert not Path(WTCTL).exists() and not Path('/etc/wtctl').exists()
    finally:
        for path in hidden:
            Path(str(path) + '.hidden').rename(path)

    output = command(*INSTALL)
    assert b'wtctl apply /etc/wtctl/wtctl.ini' in output, output
    assert Path('/test/boot-enabled').exists(), 'boot startup not registered'
    assert b'Supervisor: running' in command(WTCTL, 'status')
    assert field('/etc/wtctl/activation-state', 'manager_url') == MAIN
    assert Path('/etc/wtctl/accepted-current').exists() and not Path('/etc/wtctl/active.ini').exists()
    sample = SAMPLE.read_text()
    assert 'url=' + MAIN in sample and 'REPLACE-ME' in sample
    assert b'replace the sample placeholder' in command(WTCTL, 'validate', str(SAMPLE), success=False)
    assert b'KO invalid-configuration' in command(WTCTL, 'apply', str(SAMPLE), success=False)
    assert not Path('/etc/wtctl/desired.ini').exists(), 'unedited sample became desired'
    print('ok - no-parameter install: idle service, boot registration, rejected sample placeholders')

    output = command(*INSTALL, success=False)
    assert b'already installed' in output and b'wtctl apply' in output, output
    print('ok - rerun refused with update instructions')

    edited = (sample.replace('wss://REPLACE-ME.invalid', 'wss://example.com')
              .replace('https://REPLACE-ME.invalid/wstunnel', 'https://localhost:18888/binary')
              .replace('enabled=true', 'enabled=false'))
    SAMPLE.write_text(edited)
    assert command(WTCTL, 'apply', str(SAMPLE)).splitlines()[-1] == b'OK 0'
    assert Path('/etc/wtctl/active.ini').read_text() == edited
    assert field('/etc/wtctl/activation-state', 'wstunnel_url') == 'https://localhost:18888/binary'
    assert Path('/usr/sbin/wtctl').read_bytes() == Path('/work/wtctl').read_bytes(), 'unchanged URL replaced manager'
    print('ok - first apply of the edited sample needs no manager download')

    uninstall(purge=False)
    output = command(*INSTALL)
    assert b'Keeping existing /etc/wtctl/wtctl.ini' in output, output
    assert SAMPLE.read_text() == edited
    assert field('/etc/wtctl/activation-state', 'wstunnel_url') == 'https://localhost:18888/binary'
    assert command(WTCTL, 'apply', str(SAMPLE)).splitlines()[-1] == b'OK 0'
    uninstall()
    print('ok - reinstall after uninstall keeps the configuration and accepted setup')

    # Truncation cannot run partially received installer actions.
    streamed(success=False, source=installer_source[:installer_source.index(b'TARGET=')])
    assert not Path(WTCTL).exists()
    for mode in ('fail', 'invalid', 'syntax'):
        streamed(success=False, mode=mode)
        assert not Path(WTCTL).exists() and not Path('/etc/wtctl').exists()
        assert not list(Path('/usr/sbin').glob('wtctl.new.*')), 'bootstrap left staging scripts'
    streamed()
    calls = Path('/test/bootstrap.calls').read_text()
    assert MAIN in calls and '--proto =https --proto-redir =https' in calls
    assert b'Supervisor: running' in command(WTCTL, 'status')
    print('ok - streamed install fetches main over HTTPS; truncated or invalid streams change nothing')
    print('No-parameter installer checks passed.')
finally:
    uninstall()
