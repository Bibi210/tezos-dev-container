"""Check dependency invalidation and failure handling without installing opam."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'scripts/install-opam-deps.sh'


class DependencyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.checkout = Path(self.temp.name)
        for name in ('scripts', 'opam/virtual', 'src'):
            (self.checkout / name).mkdir(parents=True)
        for name in ('scripts/version.sh', 'scripts/install_build_deps.rust.sh',
                     'rust-toolchain', 'opam/virtual/octez-deps.opam.locked'):
            (self.checkout / name).write_text('initial\n')
        installer = self.checkout / 'scripts/install_build_deps.sh'
        installer.write_text('''#!/bin/sh
set -eu
test "$1" = --dev
if [ -f fail ]; then exit 42; fi
mkdir -p _opam/.opam-switch/build _opam/.opam-switch/sources
echo installed >> installations
''')
        installer.chmod(0o755)

    def install(self, check=True):
        return subprocess.run([str(HELPER)], cwd=self.checkout, text=True,
                              capture_output=True, check=check)

    def count(self):
        return len((self.checkout / 'installations').read_text().splitlines())

    def test_source_change_reuses_switch(self):
        self.install()
        (self.checkout / 'src/example.ml').write_text('changed source')
        result = self.install()
        self.assertIn('unchanged', result.stdout)
        self.assertEqual(self.count(), 1)

    def test_each_dependency_input_invalidates_switch(self):
        self.install()
        paths = ('scripts/version.sh', 'scripts/install_build_deps.rust.sh',
                 'rust-toolchain', 'opam/virtual/octez-deps.opam.locked',
                 'scripts/install_build_deps.sh')
        for index, name in enumerate(paths, start=2):
            with self.subTest(name=name):
                path = self.checkout / name
                path.write_text(path.read_text() + '\n# changed\n')
                self.install()
                self.assertEqual(self.count(), index)

    def test_added_and_removed_manifest_invalidates_switch(self):
        self.install()
        path = self.checkout / 'opam/virtual/new.opam'
        path.write_text('new dependency')
        self.install()
        path.unlink()
        self.install()
        self.assertEqual(self.count(), 3)

    def test_failure_is_retried_without_recording_success(self):
        self.install()
        stamp = self.checkout / '_opam/.tezos-dev-container-deps'
        previous = stamp.read_text()
        (self.checkout / 'rust-toolchain').write_text('new version')
        failure = self.checkout / 'fail'
        failure.touch()
        for _ in range(2):
            self.assertEqual(self.install(check=False).returncode, 42)
            self.assertEqual(stamp.read_text(), previous)
        failure.unlink()
        self.install()
        self.assertEqual(self.count(), 2)
        self.assertNotEqual(stamp.read_text(), previous)

    def test_missing_required_input_fails(self):
        (self.checkout / 'rust-toolchain').unlink()
        self.assertNotEqual(self.install(check=False).returncode, 0)
        self.assertFalse((self.checkout / 'installations').exists())

    def test_installation_cleans_temporary_build_files(self):
        self.install()
        self.assertFalse((self.checkout / '_opam/.opam-switch/build').exists())
        self.assertFalse((self.checkout / '_opam/.opam-switch/sources').exists())
        self.assertTrue((self.checkout / '_opam/.tezos-dev-container-deps').exists())
