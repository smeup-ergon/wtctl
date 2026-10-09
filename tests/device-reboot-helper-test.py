#!/usr/bin/env python3
"""Local regression for the physical helper's exact configuration comparison."""
import importlib.util
import io
from pathlib import Path
import tarfile
import unittest

spec = importlib.util.spec_from_file_location('reboot', Path(__file__).with_name('device-reboot-test.py'))
reboot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reboot)


def archive(directory_mtime=1, content=b'format=1\n', mode=0o600, extra=False):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w') as tar:
        directory = tarfile.TarInfo('wtctl')
        directory.type = tarfile.DIRTYPE
        directory.mode = 0o700
        directory.mtime = directory_mtime
        tar.addfile(directory)
        item = tarfile.TarInfo('wtctl/global')
        item.mode = mode
        item.size = len(content)
        tar.addfile(item, io.BytesIO(content))
        if extra:
            tar.addfile(tarfile.TarInfo('wtctl/unexpected'))
    return stream.getvalue()


class RestorationTests(unittest.TestCase):
    def test_busybox_changed_directory_mtime_is_not_changed_configuration(self):
        self.assertNotEqual(archive(1), archive(2))
        self.assertEqual(reboot.config_entries(archive(1)), reboot.config_entries(archive(2)))

    def test_changed_configuration_fails(self):
        self.assertNotEqual(reboot.config_entries(archive()), reboot.config_entries(archive(content=b'changed')))

    def test_changed_permissions_fail(self):
        self.assertNotEqual(reboot.config_entries(archive()), reboot.config_entries(archive(mode=0o644)))

    def test_extra_file_fails(self):
        self.assertNotEqual(reboot.config_entries(archive()), reboot.config_entries(archive(extra=True)))


if __name__ == '__main__':
    unittest.main()
