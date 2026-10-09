#!/usr/bin/env python3
"""Exercise phased CLI evidence/exit behavior at fake SSH/Docker boundaries."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('onsite', Path(__file__).with_name('device-onsite-test.py'))
onsite = importlib.util.module_from_spec(spec)
spec.loader.exec_module(onsite)


class UDPResultTests(unittest.TestCase):
    def run_phase(self, failing_indices):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = SimpleNamespace(private=root / 'private', output=root / 'result.json',
                                   identity=root / 'key', target='root@192.0.2.1')
            session = onsite.Session(args)
            session.state['prepared'] = True
            session.save()
            stopped = False
            exchanges = count = 0
            commands = []

            def transport(argv, **kwargs):
                nonlocal stopped, exchanges, count
                stdout = b''
                status = 0
                if argv[0] == 'ssh':
                    command = argv[-1]
                    commands.append(command)
                    if 'wtctl stop os_rudp' in command:
                        stopped = True
                    elif 'wtctl start os_rudp' in command:
                        stopped = False
                    elif command.endswith('wtctl status'):
                        stdout = ('\n'.join(name + ' ' + ('stopped' if stopped and name == 'os_rudp' else 'running')
                                             for name in session.names)).encode()
                elif argv[0] == 'docker':
                    code = argv[-1]
                    if 'udp-count' in code:
                        stdout = str(count).encode()
                    elif 'socket.SOCK_DGRAM' in code:
                        exchanges += 1
                        if exchanges in failing_indices:
                            status = 1
                        else:
                            count += 16
                            stdout = json.dumps({'bytes_echoed': 16448, 'rounds': 16}).encode()
                    else:
                        self.fail('Unexpected peer operation')
                else:
                    self.fail('Unexpected transport')
                return subprocess.CompletedProcess(argv, status, stdout, b'')

            argv = ['device-onsite-test.py', 'udp', '--private', str(args.private),
                    '--identity', str(args.identity), '--target', args.target,
                    '--host-ip', '192.0.2.2', '--probe', str(root / 'probe'),
                    '--output', str(args.output), '--yes']
            with patch.object(sys, 'argv', argv), patch.object(onsite.subprocess, 'run', transport), \
                    patch.object(onsite.time, 'sleep'), contextlib.redirect_stdout(io.StringIO()):
                status = onsite.main()
            evidence = json.loads(args.output.read_text())
            self.assertEqual(len(evidence['udp_comparison']), 6)
            self.assertFalse(evidence['udp_cause_isolated'])
            self.assertNotIn('prefix', evidence)
            direct = next(command for command in commands if ' RUST_LOG=off exec ' in command)
            self.assertIn('SSL_CERT_FILE=/etc/wtctl/onsite-test-ca.pem', direct)
            self.assertIn('--tls-verify-certificate', direct)
            self.assertNotIn('--tls-ca-certificate', direct)
            return status, evidence

    def test_managed_and_direct_failures_are_retained_and_exit_nonzero(self):
        status, evidence = self.run_phase({1, 4})
        self.assertEqual(status, 1)
        self.assertEqual(len(evidence['failed_tests']), 2)
        self.assertEqual(sum(row['passed'] for row in evidence['udp_comparison']), 4)

    def test_clean_comparison_does_not_claim_historical_resolution(self):
        status, evidence = self.run_phase(set())
        self.assertEqual(status, 0)
        self.assertEqual(evidence['failed_tests'], [])
        self.assertFalse(evidence['tests'][-1]['historical_failure_resolved'])


if __name__ == '__main__':
    unittest.main()
