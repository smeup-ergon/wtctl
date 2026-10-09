#!/usr/bin/env python3
"""Phased, owner-approved physical tests; never power-cycle without an operator.

Prepare an empty boot-enabled RAM deployment, verify an operator power-cycle,
run bounded load/stream and managed-vs-direct UDP checks, interrupt only the
identified Wi-Fi WAN with an independent timed restore, then restore baseline.
Requires fresh known-host SSH key authentication. No passwords or signed URLs
are accepted on argv or published. Private recovery/state stays outside the repo.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import time

spec = importlib.util.spec_from_file_location('reboot_helper', Path(__file__).with_name('device-reboot-test.py'))
reboot_helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reboot_helper)


class Session:
    def __init__(self, args):
        self.args = args
        self.root = args.private
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(self.root, 0o700)
        self.state_file = self.root / 'session.json'
        self.state = json.loads(self.state_file.read_text()) if self.state_file.exists() else {
            'container': 'wtctl-onsite-' + secrets.token_hex(6), 'prefix': secrets.token_hex(16),
            'tests': [], 'failed_tests': [], 'cleanup_errors': [], 'baseline_restored': False,
            'scope': 'Selected bounded physical phases; not historical UDP resolution or production qualification',
            'production_qualified': False}
        self.base = ['ssh', '-S', 'none', '-i', str(args.identity), '-o', 'IdentitiesOnly=yes',
                     '-o', 'PubkeyAcceptedAlgorithms=+ssh-rsa', '-o', 'BatchMode=yes',
                     '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=5',
                     '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=2', args.target]
        self.probe = '/tmp/wtctl-onsite-probe'
        self.ca = '/etc/wtctl/onsite-test-ca.pem'
        self.names = ['os_ftcp', 'os_fudp', 'os_rtcp', 'os_rudp']

    def save(self):
        self.state_file.write_text(json.dumps(self.state, indent=2) + '\n')
        os.chmod(self.state_file, 0o600)
        # Only sanitized evidence goes into the repository.
        evidence = {k: v for k, v in self.state.items() if k not in ('prefix', 'container')}
        self.args.output.parent.mkdir(parents=True, exist_ok=True)
        self.args.output.write_text(json.dumps(evidence, indent=2) + '\n')

    def record(self, name, **metrics):
        row = {'name': name, **metrics}
        self.state['tests'].append(row)
        self.save()
        print('PASS ' + json.dumps(row), flush=True)

    def failure(self, name, error):
        self.state['failed_tests'].append({'name': name, 'error': type(error).__name__})
        self.save()
        print('FAIL ' + name + ' (' + type(error).__name__ + ')', flush=True)

    def ssh(self, command, data=None, timeout=120):
        proc = subprocess.run(self.base + ['set -e;\n' + command], input=data,
                              capture_output=True, timeout=timeout)
        if proc.returncode:
            raise RuntimeError('SSH command failed (output suppressed)')
        return proc.stdout

    def docker(self, *command, timeout=120):
        proc = subprocess.run(['docker', *command], capture_output=True, timeout=timeout)
        if proc.returncode:
            raise RuntimeError('Peer command failed (output suppressed)')
        return proc.stdout

    def wait(self, callback, seconds=120):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try:
                value = callback()
                if value:
                    return value
            except (RuntimeError, subprocess.TimeoutExpired):
                pass
            time.sleep(2)
        raise TimeoutError('Bounded physical-test deadline expired')

    def upload(self):
        self.ssh('umask 077; dd of=' + self.probe + ' 2>/dev/null; chmod 700 ' + self.probe,
                 self.args.probe.read_bytes())

    def rows(self):
        return self.ssh('wtctl status').decode().splitlines()

    def ready(self):
        rows = self.rows()
        return all(any(line.startswith(name + ' ') and 'running' in line for line in rows) for name in self.names)

    def controls(self):
        return self.ssh('sha256sum /etc/config/network /etc/config/firewall /etc/config/system /etc/nginx/nginx.conf')

    def udp_count(self):
        return int(self.docker('exec', self.state['container'], 'python3', '-c',
                              "from pathlib import Path;p=Path('/evidence/udp-count');print(p.read_text() if p.exists() else '0')").strip())

    def reverse(self, protocol='tcp', port=None):
        port = port or (20003 if protocol == 'tcp' else 20004)
        code = """
import json,socket,time
protocol=PROTOCOL
s=socket.socket(socket.AF_INET,socket.SOCK_STREAM if protocol=='tcp' else socket.SOCK_DGRAM)
s.settimeout(20)
s.connect(('127.0.0.1',PORT))
start=time.monotonic()
count=64 if protocol=='tcp' else 16
for i in range(count):
    payload=i.to_bytes(4,'big')+bytes(range(256))*(256 if protocol=='tcp' else 4)
    s.sendall(payload)
    data=bytearray()
    while len(data)<len(payload):
        block=s.recv(len(payload)-len(data))
        if not block: raise RuntimeError('EOF')
        data.extend(block)
        if protocol=='udp': break
    assert data==payload
s.close()
print(json.dumps({'bytes_echoed':count*len(payload),'rounds':count,'elapsed_seconds':time.monotonic()-start}))
""".replace('PROTOCOL', repr(protocol)).replace('PORT', str(port))
        return json.loads(self.docker('exec', self.state['container'], 'python3', '-c', code))

    def traffic(self, label, udp=True):
        for protocol in ('tcp', 'udp') if udp else ('tcp',):
            for direction in ('forward', 'reverse'):
                name = label + ' ' + direction + ' ' + protocol
                before = self.udp_count() if protocol == 'udp' else None
                try:
                    if direction == 'forward':
                        port = '20001' if protocol == 'tcp' else '20002'
                        metrics = json.loads(self.ssh(self.probe + ' ' + protocol + ' 127.0.0.1 ' + port))
                    else:
                        metrics = self.reverse(protocol)
                    if before is not None:
                        metrics['peer_echoed_datagrams'] = self.udp_count() - before
                    self.record(name, **metrics)
                except (RuntimeError, subprocess.TimeoutExpired) as error:
                    self.failure(name, error)

    def prepare(self):
        assert not self.state.get('prepared'), 'Session already prepared'
        self.ssh('/etc/init.d/wtctl enabled; test -x /tmp/wtctl/bin/wstunnel; '
                 'test -z "$(ls -A /etc/wtctl/servers)"; test -z "$(ls -A /etc/wtctl/tunnels)"; '
                 '! netstat -lnt | grep -Eq "127\\.0\\.0\\.1:20001[[:space:]]"; '
                 '! netstat -lnu | grep -Eq "127\\.0\\.0\\.1:20002[[:space:]]"')
        candidate = hashlib.sha256(Path('wtctl').read_bytes()).hexdigest()
        assert self.ssh('sha256sum /usr/sbin/wtctl').decode().split()[0] == candidate
        self.state['candidate_sha256'] = candidate
        for file, data in (('config.tar', self.ssh('tar -cf - -C /etc wtctl')),
                           ('control-hashes', self.controls()), ('packages', self.ssh('opkg list-installed'))):
            (self.root / file).write_bytes(data)
            os.chmod(self.root / file, 0o600)
        self.ssh('umask 077; test -d /root/wtctl-onsite-recovery; '
                 'dd of=/root/wtctl-onsite-recovery/config.tar 2>/dev/null', (self.root / 'config.tar').read_bytes())
        self.state['boot_id_before_power'] = self.ssh('cat /proc/sys/kernel/random/boot_id').decode().strip()
        self.state['prepared'] = True
        self.save()
        self.docker('run', '-d', '--platform', 'linux/amd64', '--name', self.state['container'],
                    '-e', 'TEST_HOST_IP=' + self.args.host_ip, '-e', 'TEST_PREFIX=' + self.state['prefix'],
                    '-p', self.args.host_ip + ':24443:24443/tcp', '-p', self.args.host_ip + ':20001:20001/tcp',
                    '-p', self.args.host_ip + ':20002:20002/udp', 'wtctl-device-peer:local')
        certificate = self.wait(lambda: self.docker('exec', self.state['container'], 'python3', '-c',
                                     "from pathlib import Path;print(Path('/evidence/ca.pem').read_text(),end='')"))
        self.upload()
        self.ssh('umask 077; dd of=' + self.ca + ' 2>/dev/null', certificate)
        self.ssh(shlex.join(['wtctl', 'server', 'add', 'os_peer', '--endpoint',
                            'wss://' + self.args.host_ip + ':24443', '--auth', 'path',
                            '--prefix', self.state['prefix'], '--ca', self.ca]))
        for name, direction, protocol, port in (
                ('os_ftcp', 'forward', 'tcp', 20001), ('os_fudp', 'forward', 'udp', 20002),
                ('os_rtcp', 'reverse', 'tcp', 20003), ('os_rudp', 'reverse', 'udp', 20004),
                ('os_disabled', 'forward', 'tcp', 20012)):
            target = '127.0.0.1' if direction == 'forward' else self.args.host_ip
            self.ssh(shlex.join(['wtctl', 'tunnel', 'add', name, '--server', 'os_peer',
                                '--direction', direction, '--protocol', protocol, '--listen', str(port),
                                '--target', target, '--port', '20001' if protocol == 'tcp' else '20002']))
            if name != 'os_disabled':
                self.ssh('wtctl enable ' + name)
        self.ssh('wtctl apply')
        self.wait(self.ready)
        self.record('Empty baseline privately backed up; four enabled test clients and disabled control ready')
        self.traffic('Before power-cycle')
        assert not self.state['failed_tests'], 'Preflight payload failed; do not power-cycle'
        self.ssh('sync')
        self.record('Configuration flushed; ready for owner physical power-cycle')

    def power_check(self):
        assert self.state.get('prepared')
        before = self.state['boot_id_before_power']
        after = self.wait(lambda: (lambda value: value if value != before else None)(
                         self.ssh('cat /proc/sys/kernel/random/boot_id', timeout=20).decode().strip()), 600)
        self.state['boot_id_after_power'] = after
        self.ssh('test ! -e ' + self.probe + '; test -f ' + self.ca)
        self.wait(self.ready, 300)
        self.ssh('test -x /tmp/wtctl/bin/wstunnel; test ! -e /etc/wtctl/bin/wstunnel; '
                 'test "$(awk -F= \'$1=="pid" {print $2}\' /tmp/wtctl/daemon)" = '
                 '"$(ubus call service list \'{"name":"wtctl"}\' | jsonfilter -e \'@.wtctl.instances.*.pid\')"')
        assert any(line.startswith('os_disabled ') and 'stopped' in line for line in self.rows())
        self.upload()
        self.record('Operator physical power-cycle: changed boot ID, lost RAM probe, procd RAM binary recovery, disabled control stopped')
        self.traffic('After power-cycle')
        self.state['power_cycle_verified'] = True
        self.save()

    def sample(self):
        raw = self.ssh("""awk '/^cpu / {n=0;for(i=2;i<=9;i++)n+=$i;print "cpu " n}' /proc/stat
awk '/^MemAvailable:/ {print "available " $2}' /proc/meminfo
for f in /tmp/wtctl/daemon /tmp/wtctl/tunnels/*/worker /tmp/wtctl/tunnels/*/child; do
[ -f "$f" ] || continue
pid=$(awk -F= '$1=="pid" {print $2}' "$f")
[ -r "/proc/$pid/stat" ] || continue
printf 'ticks %s ' "$pid"; awk '{sub(/^.*\\) /, "");print $12+$13+$14+$15}' "/proc/$pid/stat"
awk -v pid="$pid" '/^VmRSS:/ {print "rss " pid " " $2}' "/proc/$pid/status"
done
for f in /tmp/wtctl/tunnels/*/status; do
[ -f "$f" ] || continue
printf 'restarts ';awk -F= '$1=="restarts" {print $2}' "$f"
done
printf 'flash ';df -Pk /overlay | awk 'END {print $4}'
""").decode()
        row = {'ticks': {}, 'rss': {}, 'restarts': 0}
        for line in raw.splitlines():
            parts = line.split()
            if parts[0] in ('ticks', 'rss'):
                row[parts[0]][parts[1]] = int(parts[2])
            else:
                row[parts[0]] = row.get(parts[0], 0) + int(parts[1])
        row['elapsed'] = time.monotonic()
        return row

    def printer(self):
        code = """
import json,socket,time
start=time.monotonic();total=0;connections=0
# Printer-like reverse TCP: mixed-size bursts, idle on an established stream,
# explicit close/reopen. Controlled echo sink, never a physical printer.
for session in range(3):
    s=socket.create_connection(('127.0.0.1',20003),timeout=20);s.settimeout(20)
    connections+=1
    for index,size in enumerate([1,127,4096,65536,1048576,31,262144]):
        payload=(bytes(range(256))*((size+255)//256))[:size]
        s.sendall(payload);data=bytearray()
        while len(data)<len(payload):
            block=s.recv(min(65536,len(payload)-len(data)))
            if not block:raise RuntimeError('EOF')
            data.extend(block)
        assert data==payload
        total+=len(payload)
        time.sleep(10 if index in (2,4) else 0.2)
    s.close();time.sleep(2)
print(json.dumps({'bytes_echoed':total,'connections':connections,'idle_intervals_seconds':10,'elapsed_seconds':time.monotonic()-start,'real_printer':False}))
"""
        self.record('Printer-like reverse TCP burst/idle/reconnect stream',
                    **json.loads(self.docker('exec', self.state['container'], 'python3', '-c', code, timeout=240)))

    def load(self):
        assert self.state.get('power_cycle_verified')
        duration = self.args.seconds
        code = """
import json,socket,time
s=socket.create_connection(('127.0.0.1',20003),timeout=20);s.settimeout(20)
start=time.monotonic();rounds=0;total=0
while time.monotonic()-start<DURATION:
    payload=rounds.to_bytes(8,'big')+bytes(range(256))*256
    s.sendall(payload);data=bytearray()
    while len(data)<len(payload):
        block=s.recv(len(payload)-len(data))
        if not block:raise RuntimeError('EOF')
        data.extend(block)
    assert data==payload
    total+=len(payload);rounds+=1
s.close()
print(json.dumps({'bytes_echoed':total,'rounds':rounds,'elapsed_seconds':time.monotonic()-start}))
""".replace('DURATION', str(duration))
        samples = [self.sample()]
        start = time.monotonic()
        def reverse_load():
            return json.loads(self.docker('exec', self.state['container'], 'python3', '-c', code, timeout=duration+120))
        def forward_load():
            total = checks = 0
            while time.monotonic()-start < duration:
                row = json.loads(self.ssh(self.probe + ' tcp 127.0.0.1 20001'))
                total += row['bytes_echoed']; checks += 1
            return {'bytes_echoed': total, 'verified_connections': checks, 'elapsed_seconds': time.monotonic()-start}
        with ThreadPoolExecutor(max_workers=2) as pool:
            reverse_job = pool.submit(reverse_load)
            forward_job = pool.submit(forward_load)
            while time.monotonic()-start < duration:
                time.sleep(min(30, max(0, duration-(time.monotonic()-start))))
                samples.append(self.sample())
                assert self.ready(), 'Client not running during sustained load'
                assert samples[-1]['available'] > 4096, 'Low available memory'
                if reverse_job.done():
                    reverse_job.result()
                if forward_job.done():
                    forward_job.result()
            reverse_metrics, forward_metrics = reverse_job.result(), forward_job.result()
        cpu = []
        for first, second in zip(samples, samples[1:]):
            common = first['ticks'].keys() & second['ticks'].keys()
            delta = sum(second['ticks'][pid]-first['ticks'][pid] for pid in common)
            cpu.append(100*delta/(second['cpu']-first['cpu']))
        assert samples[-1]['restarts'] == samples[0]['restarts'], 'Owned client restarted during load'
        self.record('Native sustained concurrent forward/reverse TCP with four configured clients',
                    requested_seconds=duration, forward=forward_metrics, reverse=reverse_metrics,
                    sample_count=len(samples), aggregate_owned_cpu_mean_percent=round(sum(cpu)/len(cpu),2),
                    aggregate_owned_cpu_peak_percent=round(max(cpu),2),
                    rss_sum_min_kib=min(sum(row['rss'].values()) for row in samples),
                    rss_sum_max_kib=max(sum(row['rss'].values()) for row in samples),
                    mem_available_min_kib=min(row['available'] for row in samples),
                    mem_available_final_kib=samples[-1]['available'],
                    restarts_before=samples[0]['restarts'], restarts_after=samples[-1]['restarts'],
                    note='RSS double-counts shared pages; two TCP clients active, UDP clients idle; bounded workload only')
        self.printer()
        self.traffic('After sustained load', udp=False)

    def udp(self):
        # Bounded matched command comparison. No endless retries or cause claims.
        self.wait(self.ready)
        observations = []
        for mode in ('managed', 'direct'):
            if mode == 'direct':
                self.ssh('wtctl stop os_rudp')
                self.wait(lambda: any(line.startswith('os_rudp ') and 'stopped' in line for line in self.rows()))
                command = shlex.join(['/tmp/wtctl/bin/wstunnel', 'client', '--tls-verify-certificate',
                    '--nb-worker-threads', '1', '--reverse-tunnel-connection-retry-max-backoff', '30s',
                    '-R', 'udp://127.0.0.1:20004:' + self.args.host_ip + ':20002',
                    '--http-upgrade-path-prefix', self.state['prefix'],
                    'wss://' + self.args.host_ip + ':24443'])
                # Dedicated root-private fixture tracks the exact owned direct PID.
                self.ssh('umask 077; (trap "" HUP; SSL_CERT_FILE=' + self.ca +
                         ' RUST_LOG=off exec ' + command + ') </dev/null >/dev/null 2>&1 & '
                         'pid=$!; start=$(awk \'{sub(/^.*\\) /, "");print $20}\' /proc/$pid/stat); '
                         'printf "%s %s\\n" "$pid" "$start" > /tmp/wtctl-onsite-direct.pid')
            time.sleep(8)
            try:
                for iteration in range(3):
                    before = self.udp_count()
                    try:
                        metrics = self.reverse('udp')
                        observations.append({'mode': mode, 'iteration': iteration+1, 'passed': True,
                                             'peer_echoed_datagrams': self.udp_count()-before, **metrics})
                    except (RuntimeError, subprocess.TimeoutExpired) as error:
                        observations.append({'mode': mode, 'iteration': iteration+1, 'passed': False,
                                             'peer_echoed_datagrams': self.udp_count()-before,
                                             'error': type(error).__name__})
                        self.failure('Reverse UDP comparison ' + mode + ' iteration ' + str(iteration+1), error)
            finally:
                if mode == 'direct':
                    self.stop_direct()
                    self.ssh('wtctl start os_rudp')
                    self.wait(self.ready)
        self.state['udp_comparison'] = observations
        self.state['udp_cause_isolated'] = False
        self.save()
        self.record('Bounded equivalent managed/direct reverse-UDP comparison completed',
                    managed_passes=sum(row['passed'] for row in observations if row['mode']=='managed'),
                    direct_passes=sum(row['passed'] for row in observations if row['mode']=='direct'),
                    attempts_per_mode=3, historical_failure_resolved=False)

    def stop_direct(self):
        # Never authorize signals from a stale PID alone: verify executable and
        # fixture-specific destination in cmdline, then remove the fixture record.
        self.ssh("""if [ -f /tmp/wtctl-onsite-direct.pid ]; then
read -r pid start < /tmp/wtctl-onsite-direct.pid
case "$pid:$start" in *[!0-9:]*|:*) exit 1;; esac
if [ -r "/proc/$pid/cmdline" ] && [ "$(awk '{sub(/^.*\\) /, "");print $20}' "/proc/$pid/stat")" = "$start" ]; then
tr '\\000' ' ' < "/proc/$pid/cmdline" | grep -F 'udp://127.0.0.1:20004:' >/dev/null
kill "$pid"
fi
rm /tmp/wtctl-onsite-direct.pid
fi""")

    def wan(self):
        assert self.ssh("ubus call network.interface.wwan status | jsonfilter -e '@.l3_device'").strip() == b'wlan-sta0'
        # Prove an SSH-independent, HUP-ignoring background shell survives logout
        # before using the same mechanism for the timed interface restore.
        marker = '/tmp/wtctl-onsite-detached-ok'
        self.ssh('(trap "" HUP; sleep 5; touch ' + marker + ') </dev/null >/dev/null 2>&1 &')
        self.wait(lambda: self.ssh('test -f ' + marker + '; echo ok'), 20)
        self.ssh('rm ' + marker)
        self.record('Independent timed restore process mechanism verified before WAN interruption')
        command = """trap '' HUP
trap '/sbin/ifup wwan' EXIT TERM INT
sleep 3
printf '%s\\n' "$(date +%s)" > /root/wtctl-onsite-recovery/wan-down-at
/sbin/ifdown wwan
# Exercise missing-binary retry while truly disconnected, not just peer loss.
wtctl binary update --yes > /dev/null 2>&1
sleep 30
ubus call network.interface.wwan status > /root/wtctl-onsite-recovery/wan-offline-status
wtctl status > /root/wtctl-onsite-recovery/wan-offline-wtctl
if [ ! -e /tmp/wtctl/bin/wstunnel ]; then touch /root/wtctl-onsite-recovery/wan-offline-binary-absent; fi
sleep 90
/sbin/ifup wwan
printf '%s\\n' "$(date +%s)" > /root/wtctl-onsite-recovery/wan-up-at
trap - EXIT TERM INT
"""
        self.ssh('umask 077; dd of=/root/wtctl-onsite-recovery/wan.sh 2>/dev/null', command.encode())
        self.ssh('(trap "" HUP; exec sh /root/wtctl-onsite-recovery/wan.sh) </dev/null >/dev/null 2>&1 &')
        start = time.monotonic()
        # A fresh login must fail during the actual WAN-facing interface outage.
        time.sleep(10)
        disconnected = False
        try:
            self.ssh('echo online', timeout=15)
        except (RuntimeError, subprocess.TimeoutExpired):
            disconnected = True
        assert disconnected, 'SSH remained available; WAN loss not established'
        self.wait(lambda: self.ssh('test -f /root/wtctl-onsite-recovery/wan-up-at; echo ok', timeout=20), 600)
        offline = json.loads(self.ssh('cat /root/wtctl-onsite-recovery/wan-offline-status'))
        assert not offline['up'], 'WAN offline snapshot was not down'
        self.ssh('test -f /root/wtctl-onsite-recovery/wan-offline-binary-absent')
        offline_manager = self.ssh('cat /root/wtctl-onsite-recovery/wan-offline-wtctl').decode()
        assert 'download-failed' in offline_manager or 'downloading' in offline_manager
        assert 'Download retry epoch: 0' not in offline_manager, 'No download retry scheduled'
        self.wait(self.ready, 300)
        self.ssh('test -x /tmp/wtctl/bin/wstunnel')
        down = int(self.ssh('cat /root/wtctl-onsite-recovery/wan-down-at'))
        up = int(self.ssh('cat /root/wtctl-onsite-recovery/wan-up-at'))
        self.record('True Wi-Fi WAN loss, unavailable RAM binary, scheduled retry and unattended restoration',
                    wan_down_seconds=up-down, elapsed_until_recovery_seconds=round(time.monotonic()-start,2),
                    ssh_unavailable_during_outage=True, offline_interface_up=offline['up'],
                    saved_network_config_modified=False)
        self.traffic('After true WAN restoration')

    def boot_wan(self):
        # A temporary, explicitly marked boot fixture holds the actual WAN down
        # before wtctl's START=99. It changes no saved network/Wi-Fi settings.
        hook = '/etc/init.d/wtctl-onsite-wan'
        before = self.ssh('cat /proc/sys/kernel/random/boot_id').decode().strip()
        self.ssh('test ! -e ' + hook + '; /etc/init.d/wtctl enabled; '
                 'test "$(ubus call network.interface.wwan status | jsonfilter -e \'@.l3_device\')" = wlan-sta0')
        restore = """trap '' HUP
trap '/sbin/ifup wwan' EXIT TERM INT
sleep 35
ubus call network.interface.wwan status > /root/wtctl-onsite-recovery/boot-wan-offline-status
wtctl status > /root/wtctl-onsite-recovery/boot-wan-offline-wtctl
if [ ! -e /tmp/wtctl/bin/wstunnel ]; then touch /root/wtctl-onsite-recovery/boot-wan-binary-absent; fi
sleep 90
/sbin/ifup wwan
printf '%s\\n' "$(date +%s)" > /root/wtctl-onsite-recovery/boot-wan-up-at
trap - EXIT TERM INT
"""
        init = """#!/bin/sh /etc/rc.common
# wtctl onsite acceptance fixture; NOT part of installed manager.
START=98
start() {
    /sbin/ifdown wwan
    date +%s > /root/wtctl-onsite-recovery/boot-wan-down-at
    cat /proc/sys/kernel/random/boot_id > /root/wtctl-onsite-recovery/boot-wan-id
    (trap '' HUP; exec sh /root/wtctl-onsite-recovery/boot-wan-restore.sh) </dev/null >/dev/null 2>&1 &
}
"""
        self.ssh('umask 077; dd of=/root/wtctl-onsite-recovery/boot-wan-restore.sh 2>/dev/null; '
                 'sh -n /root/wtctl-onsite-recovery/boot-wan-restore.sh', restore.encode())
        self.ssh('umask 077; dd of=' + hook + ' 2>/dev/null; chmod 700 ' + hook + '; sh -n ' + hook,
                 init.encode())
        self.ssh(hook + ' enable; sync')
        start = time.monotonic()
        try:
            self.ssh('reboot', timeout=20)
        except (RuntimeError, subprocess.TimeoutExpired):
            pass
        after = self.wait(lambda: (lambda value: value if value != before else None)(
                         self.ssh('cat /proc/sys/kernel/random/boot_id', timeout=20).decode().strip()), 600)
        self.wait(lambda: self.ssh('test -f /root/wtctl-onsite-recovery/boot-wan-up-at; echo ok'), 120)
        assert self.ssh('cat /root/wtctl-onsite-recovery/boot-wan-id').decode().strip() == after
        offline = json.loads(self.ssh('cat /root/wtctl-onsite-recovery/boot-wan-offline-status'))
        assert not offline['up']
        self.ssh('test -f /root/wtctl-onsite-recovery/boot-wan-binary-absent; test ! -e ' + self.probe)
        offline_manager = self.ssh('cat /root/wtctl-onsite-recovery/boot-wan-offline-wtctl').decode()
        assert 'Supervisor: running' in offline_manager
        assert 'download-failed' in offline_manager or 'downloading' in offline_manager
        assert 'Download retry epoch: 0' not in offline_manager
        self.wait(self.ready, 300)
        self.ssh('test -x /tmp/wtctl/bin/wstunnel; ' + hook + ' disable; rm ' + hook)
        self.upload()
        down = int(self.ssh('cat /root/wtctl-onsite-recovery/boot-wan-down-at'))
        up = int(self.ssh('cat /root/wtctl-onsite-recovery/boot-wan-up-at'))
        self.record('WAN unavailable at boot: RAM binary absent, manager alive/retrying, unattended recovery',
                    boot_id_before=before, boot_id_after=after, wan_down_seconds=up-down,
                    elapsed_until_recovery_seconds=round(time.monotonic()-start,2),
                    temporary_boot_fixture_removed=True, saved_network_config_modified=False)
        self.traffic('After offline-boot WAN restoration')

    def cleanup(self):
        self.ssh('if [ -f /etc/init.d/wtctl-onsite-wan ]; then '
                 'grep -F "wtctl onsite acceptance fixture" /etc/init.d/wtctl-onsite-wan >/dev/null; '
                 '/etc/init.d/wtctl-onsite-wan disable; rm /etc/init.d/wtctl-onsite-wan; fi')
        self.stop_direct()
        original = (self.root / 'config.tar').read_bytes()
        self.ssh('/etc/init.d/wtctl stop; wtctl shutdown; rm -rf /etc/wtctl; '
                 'tar -xf - -C /etc; rm -f ' + self.probe, original)
        assert reboot_helper.config_entries(self.ssh('tar -cf - -C /etc wtctl')) == reboot_helper.config_entries(original)
        self.ssh('/etc/init.d/wtctl start; /etc/init.d/wtctl enabled; '
                 'test -z "$(ls -A /etc/wtctl/servers)"; test -z "$(ls -A /etc/wtctl/tunnels)"; '
                 'test ! -e ' + self.ca + '; test ! -e ' + self.probe + '; test -x /tmp/wtctl/bin/wstunnel')
        assert self.controls() == (self.root / 'control-hashes').read_bytes()
        assert self.ssh('opkg list-installed') == (self.root / 'packages').read_bytes()
        assert self.ssh('curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1').strip() == b'200'
        assert self.ssh('sha256sum /usr/sbin/wtctl').decode().split()[0] == self.state['candidate_sha256']
        self.docker('rm', '-f', self.state['container'])
        self.state['baseline_restored'] = True
        self.record('Exact empty baseline/startup/native RAM binary/vendor hashes/packages/panel restored; peer/probe/CA removed')
        self.state['passed'] = not self.state['failed_tests'] and not self.state['cleanup_errors']
        self.save()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['prepare', 'power-check', 'load', 'udp', 'wan', 'boot-wan', 'cleanup'])
    parser.add_argument('--private', type=Path, required=True)
    parser.add_argument('--identity', type=Path, required=True)
    parser.add_argument('--target', required=True)
    parser.add_argument('--host-ip', required=True)
    parser.add_argument('--probe', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--seconds', type=int, default=1800, choices=[60, 1800])
    parser.add_argument('--yes', action='store_true')
    args = parser.parse_args()
    args.host_ip = str(ipaddress.IPv4Address(args.host_ip))
    if not args.yes or args.target.startswith('-'):
        parser.error('Explicit --yes and a valid target are required')
    session = Session(args)
    if session.ssh('wtctl --version').strip() != b'0.1.0':
        parser.error('Historical 0.1.0 harness: no device changes performed; automatic lifecycle needs new qualification')
    try:
        getattr(session, args.phase.replace('-', '_'))()
    except Exception as error:
        if args.phase == 'cleanup':
            session.state['cleanup_errors'].append(type(error).__name__)
        session.failure(args.phase, error)
        return 1
    return 1 if session.state['failed_tests'] or session.state['cleanup_errors'] else 0


if __name__ == '__main__':
    raise SystemExit(main())
