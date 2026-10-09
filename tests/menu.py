"""Real PTY regressions: single-key menus, letter overflow, secrets, restoration."""
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import subprocess
import termios
import time

ENV = dict(os.environ, WTCTL_CONFIG_DIR='/test/menu-config', WTCTL_STATE_DIR='/test/menu-state')
W = '/work/wtctl'
subprocess.run([W, 'status'], env=ENV, check=True, stdout=subprocess.DEVNULL)
Path('/test/menu-state/bin').mkdir(parents=True, exist_ok=True)
shutil.copy('/fixture', '/test/menu-state/bin/wstunnel')


class Menu:
    def __init__(self):
        self.master, self.slave = pty.openpty()
        self.original = termios.tcgetattr(self.slave)
        self.process = subprocess.Popen([W, 'menu'], stdin=self.slave, stdout=self.slave, stderr=self.slave, env=ENV)
        self.pending = bytearray()
        self.transcript = bytearray()

    def wait(self, prompt):
        prompt = prompt.encode()
        deadline = time.monotonic() + 25
        while prompt not in self.pending:
            assert time.monotonic() < deadline, f'missing {prompt!r}: {bytes(self.pending)!r}'
            ready, _, _ = select.select([self.master], [], [], .2)
            if ready:
                data = os.read(self.master, 4096)
                assert data, 'menu exited unexpectedly'
                self.pending.extend(data)
                self.transcript.extend(data)
        end = self.pending.index(prompt) + len(prompt)
        del self.pending[:end]

    def answer(self, prompt, value, text=False):
        self.wait(prompt)
        os.write(self.master, value.encode() + (b'\n' if text else b''))

    def finish(self):
        assert self.process.wait(timeout=15) == 0
        assert termios.tcgetattr(self.slave) == self.original, 'terminal mode leaked'

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=15)
        os.close(self.master)
        os.close(self.slave)


menu = Menu()
try:
    menu.answer('> ', '2')
    menu.answer('0 Back\r\n> ', '1')
    menu.answer('Server name: ', 'demo', text=True)
    menu.answer('WSS endpoint: ', 'wss://example.com', text=True)
    menu.answer('0 Cancel\r\n> ', '3')
    menu.answer('Username: ', 'user', text=True)
    menu.answer('Password: ', 'hidden-menu-password', text=True)
    menu.answer('Custom CA file (empty for system trust): ', '', text=True)
    menu.answer('0 Cancel\r\n> ', '1')
    menu.answer('0 Back\r\n> ', '0')
    menu.answer('> ', '3')
    menu.answer('0 Back\r\n> ', '1')
    menu.answer('Tunnel name: ', 'sample', text=True)
    menu.answer('0 Back\r\n> ', '1')  # select server, no typed profile name
    menu.answer('0 Cancel\r\n> ', '1')
    menu.answer('0 Cancel\r\n> ', '2')
    menu.answer('Bind address [127.0.0.1]: ', '', text=True)
    menu.answer('Listen port: ', '19876', text=True)
    menu.answer('Target host: ', 'localhost', text=True)
    menu.answer('Target port: ', '80', text=True)
    menu.answer('0 Cancel\r\n> ', '1')
    menu.answer('0 Back\r\n> ', '3')
    menu.answer('0 Back\r\n> ', '1')
    menu.answer('0 Cancel\r\n> ', '1')
    menu.answer('0 Back\r\n> ', '0')
    menu.answer('> ', '2')
    menu.answer('0 Back\r\n> ', '3')
    menu.answer('0 Back\r\n> ', '1')
    menu.answer('0 Cancel\r\n> ', '1')
    menu.answer('0 Back\r\n> ', '0')
    menu.answer('> ', '0')
    menu.finish()
    assert b'hidden-menu-password' not in menu.transcript
    assert not Path('/test/menu-config/servers/demo').exists()
    assert not Path('/test/menu-config/tunnels/sample').exists()
finally:
    menu.close()

for index in range(1, 11):
    subprocess.run([W, 'server', 'add', f's{index:02}', '--endpoint', 'wss://example.com'], env=ENV, check=True, stdout=subprocess.DEVNULL)
menu = Menu()
try:
    menu.answer('> ', '2')
    menu.answer('0 Back\r\n> ', '3')
    menu.answer('a s10\r\n0 Back\r\n> ', 'A')  # uppercase accepted too
    menu.answer('0 Cancel\r\n> ', '1')
    menu.answer('0 Back\r\n> ', '0')
    menu.answer('> ', '0')
    menu.finish()
    assert not Path('/test/menu-config/servers/s10').exists()
finally:
    menu.close()

menu = Menu()
try:
    menu.answer('> ', 'x')
    menu.answer('> ', '\n')  # invalid/Enter does not accidentally exit
    menu.answer('> ', '0')
    menu.finish()
finally:
    menu.close()

stty = shutil.which('stty')
shutil.move(stty, stty + '.hidden')
menu = Menu()
try:
    menu.answer('> ', '2', text=True)
    menu.answer('0 Back\r\n> ', '1', text=True)
    menu.answer('Server name: ', 'fallback', text=True)
    menu.answer('WSS endpoint: ', 'wss://example.com', text=True)
    menu.answer('0 Cancel\r\n> ', '3', text=True)
    menu.answer('Username: ', 'user', text=True)
    Path('/test/menu-password').write_text('private-password\n')
    menu.answer('One-line password file: ', '/test/menu-password', text=True)
    menu.answer('Custom CA file (empty for system trust): ', '', text=True)
    menu.answer('0 Cancel\r\n> ', '1', text=True)
    menu.answer('0 Back\r\n> ', '0', text=True)
    menu.answer('> ', '0', text=True)
    menu.finish()
    assert b'private-password' not in menu.transcript
finally:
    menu.close()
    shutil.move(stty + '.hidden', stty)

for mode in ('eof', 'signal'):
    menu = Menu()
    try:
        menu.wait('> ')
        if mode == 'eof':
            os.write(menu.master, b'\x04')
            menu.finish()
        else:
            menu.process.send_signal(signal.SIGTERM)
            assert menu.process.wait(timeout=15) == 130
            assert termios.tcgetattr(menu.slave) == menu.original
    finally:
        menu.close()
for mode in ('eof', 'signal'):
    menu = Menu()
    try:
        menu.answer('> ', '2')
        menu.answer('0 Back\r\n> ', '1')
        menu.answer('Server name: ', 'interrupted', text=True)
        menu.answer('WSS endpoint: ', 'wss://example.com', text=True)
        menu.answer('0 Cancel\r\n> ', '3')
        menu.answer('Username: ', 'user', text=True)
        menu.wait('Password: ')
        if mode == 'eof':
            os.write(menu.master, b'\x04')
            menu.answer('0 Back\r\n> ', '0')
            menu.answer('> ', '0')
            menu.finish()
        else:
            menu.process.send_signal(signal.SIGTERM)
            assert menu.process.wait(timeout=15) == 130
            assert termios.tcgetattr(menu.slave) == menu.original
        assert not Path('/test/menu-config/servers/interrupted').exists()
        assert not list(Path('/test/menu-state').glob('secret.*'))
    finally:
        menu.close()

subprocess.run([W, 'shutdown'], env=ENV, check=True)
print('Single-key menus, overflow letters, tunnel choices, secrets, EOF/signal restoration passed.')
