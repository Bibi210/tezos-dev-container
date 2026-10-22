"""Exercise launcher replacement with read-only build outputs as a non-root user."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / 'scripts/build-tezos.sh').read_text()
LOOP = SCRIPT[SCRIPT.index('for binary in '):SCRIPT.index('\n# Commit snapshots')]


class LauncherTests(unittest.TestCase):
    def test_read_only_executable_replacement(self):
        for hardlink in (False, True):
            with self.subTest(hardlink=hardlink), tempfile.TemporaryDirectory() as directory:
                checkout = Path(directory)
                binary = checkout / '_build/install/default/bin/etherlink-governance-observer'
                binary.parent.mkdir(parents=True)
                content = '#!/bin/sh\nprintf "%s\\n" "$@"\nexit 23\n'
                binary.write_text(content)
                binary.chmod(0o555)
                launcher = checkout / binary.name
                if hardlink:
                    os.link(binary, launcher)
                else:
                    launcher.write_text(content)
                    launcher.chmod(0o555)

                subprocess.run(['bash', '-euo', 'pipefail', '-c', LOOP],
                               cwd=checkout, check=True, capture_output=True)
                self.assertEqual(binary.read_text(), content)
                self.assertEqual(binary.stat().st_mode & 0o777, 0o555)
                self.assertFalse(launcher.is_symlink())
                result = subprocess.run([str(launcher), 'two words', '*'],
                                        cwd='/', text=True, capture_output=True)
                self.assertEqual(result.returncode, 23)
                self.assertEqual(result.stdout, 'two words\n*\n')

                # A subsequent make can still copy the executable over the launcher.
                subprocess.run(['cp', '-f', str(binary), str(launcher)], check=True)
                self.assertEqual(launcher.read_text(), content)
