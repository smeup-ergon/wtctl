#!/usr/bin/env python3
"""One opt-in software reboot on an approved empty, boot-enabled OpenWrt device.

Requires verified fresh SSH key authentication and a controlled reachable Docker
peer. No password arguments, WAN changes, power cycling or automatic retry of
failed payload checks. Keeps private recovery material outside the repository.
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
import io
import tarfile


def config_entries(archive):
    """Compare configuration content, paths, ownership and modes, not dir mtimes.

    BusyBox tar extraction changes parent directory mtimes as children are made.
    Archive-byte equality therefore rejects correctly restored configuration.
    """
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        return {member.name: (member.mode, member.uid, member.gid, member.type,
                              tar.extractfile(member).read() if member.isfile()
                              else member.linkname) for member in tar}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', required=True)
    parser.add_argument('--identity', type=Path, required=True)
    parser.add_argument('--host-ip', required=True)
    parser.add_argument('--probe', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--yes-reboot', action='store_true')
    args = parser.parse_args()
    if not args.yes_reboot or args.target.startswith('-'):
        parser.error('Explicit --yes-reboot and a valid target are required')
    host = str(ipaddress.IPv4Address(args.host_ip))
    base = ['ssh', '-S', 'none', '-i', str(args.identity), '-o', 'IdentitiesOnly=yes',
            '-o', 'PubkeyAcceptedAlgorithms=+ssh-rsa', '-o', 'BatchMode=yes',
            '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=5',
            '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=2', args.target]
    result = {'passed': False, 'tests': [], 'failed_tests': [], 'cleanup_errors': [],
              'baseline_restored': False, 'reboot_performed': False,
              'wan_interface_modified': False}
    private = Path(tempfile.mkdtemp(prefix='wtctl-reboot-recovery.'))
    os.chmod(private, 0o700)
    container = 'wtctl-reboot-' + secrets.token_hex(6)
    prefix = secrets.token_hex(16)
    ram = '/tmp/wtctl-reboot-probe'
    ca = '/etc/wtctl/reboot-test-ca.pem'
    q = shlex.quote
    started = modified = False
    original = hashes = packages = None

    def ssh(command, data=None, timeout=120):
        proc = subprocess.run(base + ['set -e;\n' + command], input=data,
                              capture_output=True, timeout=timeout)
        if proc.returncode:
            raise RuntimeError('SSH operation failed (command/output suppressed)')
        return proc.stdout

    def docker(*command, timeout=100):
        proc = subprocess.run(['docker', *command], capture_output=True, timeout=timeout)
        if proc.returncode:
            raise RuntimeError('Peer operation failed (command/output suppressed)')
        return proc.stdout

    def wait(callback, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try:
                value = callback()
                if value:
                    return value
            except (RuntimeError, subprocess.TimeoutExpired):
                pass
            time.sleep(2)
        raise TimeoutError('Bounded recovery deadline expired')

    def record(name, **metrics):
        row = {'name': name, **metrics}
        result['tests'].append(row)
        print('PASS ' + json.dumps(row), flush=True)

    def controls():
        return ssh('sha256sum /etc/config/network /etc/config/firewall /etc/config/system /etc/nginx/nginx.conf')

    def upload_probe():
        ssh('umask 077; dd of=' + ram + ' 2>/dev/null; chmod 700 ' + ram,
            args.probe.read_bytes())

    def traffic(label):
        # Each payload check runs once. UDP failure is retained, never retried into a pass.
        for protocol in ('tcp', 'udp'):
            for direction in ('forward', 'reverse'):
                name = label + ' ' + direction + ' ' + protocol
                try:
                    if direction == 'forward':
                        port = '20001' if protocol == 'tcp' else '20002'
                        metrics = json.loads(ssh(ram + ' ' + protocol + ' 127.0.0.1 ' + port))
                    else:
                        code = """
import json,socket,time
protocol=PROTOCOL
s=socket.socket(socket.AF_INET,socket.SOCK_STREAM if protocol=='tcp' else socket.SOCK_DGRAM)
s.settimeout(20)
s.connect(('127.0.0.1',20003 if protocol=='tcp' else 20004))
start=time.monotonic()
payload=bytes(range(256))*256 if protocol=='tcp' else bytes(range(256))*4
count=64 if protocol=='tcp' else 16
for i in range(count):
    s.sendall(payload)
    data=bytearray()
    while len(data)<len(payload):
        block=s.recv(len(payload)-len(data))
        if not block: raise RuntimeError('EOF')
        data.extend(block)
    assert data==payload
s.close()
print(json.dumps({'bytes_echoed':len(payload)*count,'elapsed_seconds':time.monotonic()-start}))
""".replace('PROTOCOL', repr(protocol))
                        metrics = json.loads(docker('exec', container, 'python3', '-c', code))
                    record(name, **metrics)
                except (RuntimeError, subprocess.TimeoutExpired) as error:
                    result['failed_tests'].append({'name': name, 'error': type(error).__name__})
                    print('FAIL ' + name, flush=True)

    def ready():
        text = ssh('wtctl status').decode()
        return all(any(line.startswith(name + ' ') and 'running' in line for line in text.splitlines())
                   for name in ('rb_ftcp', 'rb_fudp', 'rb_rtcp', 'rb_rudp'))

    try:
        ssh('test -x /usr/sbin/wtctl; /etc/init.d/wtctl enabled; '
            'test -z "$(ls -A /etc/wtctl/servers)"; test -z "$(ls -A /etc/wtctl/tunnels)"; '
            'test -x /tmp/wtctl/bin/wstunnel; '
            '! netstat -lnt | grep -Eq "127\\.0\\.0\\.1:(20001|20011)[[:space:]]"; '
            '! netstat -lnu | grep -Eq "127\\.0\\.0\\.1:20002[[:space:]]"')
        candidate = hashlib.sha256(Path('wtctl').read_bytes()).hexdigest()
        assert ssh('sha256sum /usr/sbin/wtctl').decode().split()[0] == candidate
        result['candidate_sha256'] = candidate
        original = ssh('tar -cf - -C /etc wtctl')
        # Persist recovery data on the device as well: workstation /tmp is not
        # sufficient recovery storage across reboot or loss of the management path.
        recovery = '/root/' + container + '-recovery'
        ssh('umask 077; mkdir ' + q(recovery) + '; dd of=' +
            q(recovery + '/config.tar') + ' 2>/dev/null', original)
        (private / 'config.tar').write_bytes(original)
        os.chmod(private / 'config.tar', 0o600)
        hashes, packages = controls(), ssh('opkg list-installed')
        before = ssh('cat /proc/sys/kernel/random/boot_id').decode().strip()
        result['boot_id_before'] = before
        record('Fresh SSH authentication, exact candidate, empty boot-enabled baseline')
        docker('run', '-d', '--platform', 'linux/amd64', '--name', container,
               '-e', 'TEST_HOST_IP=' + host, '-e', 'TEST_PREFIX=' + prefix,
               '-p', host + ':24443:24443/tcp', '-p', host + ':20001:20001/tcp',
               '-p', host + ':20002:20002/udp', 'wtctl-device-peer:local')
        started = True
        certificate = wait(lambda: docker('exec', container, 'python3', '-c',
                           "from pathlib import Path;print(Path('/evidence/ca.pem').read_text(),end='')"), 90)
        modified = True
        upload_probe()
        ssh('umask 077; dd of=' + ca + ' 2>/dev/null', certificate)
        ssh('wtctl server add rb_peer --endpoint ' + q('wss://' + host + ':24443') +
            ' --auth path --prefix ' + q(prefix) + ' --ca ' + ca)
        for name, direction, protocol, port in (
                ('rb_ftcp', 'forward', 'tcp', 20001), ('rb_fudp', 'forward', 'udp', 20002),
                ('rb_rtcp', 'reverse', 'tcp', 20003), ('rb_rudp', 'reverse', 'udp', 20004),
                ('rb_disabled', 'forward', 'tcp', 20012)):
            target = '127.0.0.1' if direction == 'forward' else host
            ssh(shlex.join(['wtctl', 'tunnel', 'add', name, '--server', 'rb_peer',
                            '--direction', direction, '--protocol', protocol, '--listen', str(port),
                            '--target', target, '--port', '20001' if protocol == 'tcp' else '20002']))
            if name != 'rb_disabled':
                ssh('wtctl enable ' + name)
        ssh('wtctl apply')
        wait(ready, 120)
        time.sleep(5)
        traffic('Before reboot')
        if result['failed_tests']:
            raise RuntimeError('Pre-reboot payload failed; reboot not attempted')
        ssh('wtctl tunnel edit rb_ftcp --listen 20011; wtctl stop rb_ftcp')
        wait(lambda: any(line.startswith('rb_ftcp ') and 'stopped' in line
                        for line in ssh('wtctl status').decode().splitlines()), 60)
        record('Unapplied draft and temporary stop prepared; disabled tunnel retained')
        # Reboot may disconnect before SSH returns; only a changed boot ID proves success.
        result['reboot_requested'] = True
        try:
            ssh('sync; reboot', timeout=20)
        except (RuntimeError, subprocess.TimeoutExpired):
            pass
        start = time.monotonic()
        after = wait(lambda: (lambda value: value if value != before else None)(
                     ssh('cat /proc/sys/kernel/random/boot_id', timeout=20).decode().strip()), 600)
        result['reboot_performed'] = True
        result['boot_id_after'] = after
        record('Software reboot and fresh SSH reconnect', elapsed_seconds=round(time.monotonic()-start, 2))
        ssh('test ! -e ' + ram + '; test -f ' + ca + '; '
            'test "$(awk -F= \'$1=="listen" {print $2}\' /etc/wtctl/tunnels/rb_ftcp)" = 20011')
        record('RAM probe lost and persistent test CA retained')
        wait(ready, 300)
        ssh('test -x /tmp/wtctl/bin/wstunnel; '
            'test "$(awk -F= \'$1=="storage" {print $2}\' /etc/wtctl/global)" = ram; '
            'test ! -e /etc/wtctl/bin/wstunnel; '
            'test "$(awk -F= \'$1=="pid" {print $2}\' /tmp/wtctl/daemon)" = '
            '"$(ubus call service list \'{"name":"wtctl"}\' | jsonfilter -e \'@.wtctl.instances.*.pid\')"')
        status = ssh('wtctl status').decode()
        assert any(line.startswith('rb_disabled ') and 'stopped' in line for line in status.splitlines())
        record('procd boot ownership, RAM binary automatic recovery, enabled clients and disabled preference')
        upload_probe()
        traffic('After reboot (last-applied port and temporary-stop reset)')
    except Exception as error:
        result['failed_tests'].append({'name': 'Reboot lifecycle', 'error': type(error).__name__})
    finally:
        if modified:
            try:
                ssh('/etc/init.d/wtctl stop; wtctl shutdown; rm -rf /etc/wtctl; '
                    'tar -xf - -C /etc; rm -f ' + ram, original)
                assert config_entries(ssh('tar -cf - -C /etc wtctl')) == config_entries(original)
                ssh('/etc/init.d/wtctl start; /etc/init.d/wtctl enabled')
                assert controls() == hashes and ssh('opkg list-installed') == packages
                assert ssh('curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1').strip() == b'200'
                ssh('test -z "$(ls -A /etc/wtctl/servers)"; test -z "$(ls -A /etc/wtctl/tunnels)"; '
                    'test ! -e ' + ca + '; test ! -e ' + ram + '; test -x /tmp/wtctl/bin/wstunnel')
                result['baseline_restored'] = True
                record('Exact empty configuration, enabled startup, vendor hashes/packages/panel restored')
            except Exception as error:
                result['cleanup_errors'].append(type(error).__name__)
        if started:
            try:
                docker('rm', '-f', container)
            except Exception as error:
                result['cleanup_errors'].append(type(error).__name__)
        result['passed'] = bool(result['reboot_performed'] and result['baseline_restored']
                                and not result['failed_tests'] and not result['cleanup_errors'])
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + '\n')
        print('Private recovery retained at ' + str(private), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
