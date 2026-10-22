"""Exercise the real resolver and Docker checkout commands against local Git."""
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CheckoutTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.remote = self.directory / 'remote'
        self.env = {
            **os.environ,
            'GIT_CONFIG_GLOBAL': '/dev/null',
            'GIT_CONFIG_NOSYSTEM': '1',
            'GIT_CONFIG_COUNT': '1',
            'GIT_CONFIG_KEY_0': f'url.{self.remote.as_uri()}.insteadOf',
            'GIT_CONFIG_VALUE_0': 'https://gitlab.com/tezos/tezos.git',
            'GIT_AUTHOR_NAME': 'Test', 'GIT_COMMITTER_NAME': 'Test',
            'GIT_AUTHOR_EMAIL': 'test@example.org',
            'GIT_COMMITTER_EMAIL': 'test@example.org',
        }
        self.run_command('git', 'init', '-b', 'master', str(self.remote))
        self.first = self.commit('first')

    def run_command(self, *args, check=True, **kwargs):
        return subprocess.run(args, env=self.env, text=True, capture_output=True,
                              check=check, **kwargs)

    def commit(self, content):
        (self.remote / 'source').write_text(content)
        self.run_command('git', '-C', str(self.remote), 'add', 'source')
        self.run_command('git', '-C', str(self.remote), 'commit', '-m', content)
        return self.run_command('git', '-C', str(self.remote), 'rev-parse', 'HEAD').stdout.strip()

    def resolve(self, *args, check=True):
        return self.run_command(str(ROOT / 'scripts/resolve-tezos-commit.sh'),
                                *args, check=check)

    def checkout(self, dockerfile, destination, commit, check=True):
        instructions = re.split(r'\n(?=[A-Z]+ )', (ROOT / dockerfile).read_text())
        command, = [s[4:] for s in instructions
                    if s.startswith('RUN ') and 'git checkout' in s]
        command = command.replace('\\\n', '').replace('/home/dev/tezos', shlex.quote(str(destination)))
        self.env['GIT_COMMIT'] = commit
        return self.run_command('bash', '-euo', 'pipefail', '-c', command, check=check)

    def test_resolver_tracks_branch_and_accepts_slashes(self):
        self.assertEqual(self.resolve().stdout.strip(), self.first)
        second = self.commit('second')
        self.assertEqual(self.resolve().stdout.strip(), second)
        self.run_command('git', '-C', str(self.remote), 'branch', 'feature/test', self.first)
        self.assertEqual(self.resolve('feature/test').stdout.strip(), self.first)

    def test_resolver_rejects_missing_and_invalid_branches(self):
        for branch in ('missing', 'bad..branch'):
            with self.subTest(branch=branch):
                result = self.resolve(branch, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')

    def test_both_checkouts_remain_pinned_when_branch_advances(self):
        pinned = self.resolve().stdout.strip()
        second = self.commit('second')
        for dockerfile in ('Dockerfile.base', 'Dockerfile'):
            with self.subTest(dockerfile=dockerfile):
                destination = self.directory / dockerfile
                if dockerfile == 'Dockerfile':
                    self.checkout('Dockerfile.base', destination, second)
                self.checkout(dockerfile, destination, pinned)
                head = self.run_command('git', '-C', str(destination), 'rev-parse', 'HEAD')
                self.assertEqual(head.stdout.strip(), pinned)

    def test_nightly_advances_and_preserves_build_artifacts(self):
        destination = self.directory / 'checkout'
        self.checkout('Dockerfile.base', destination, self.first)
        marker = destination / '_build' / 'cached-artifact'
        marker.parent.mkdir()
        marker.write_text('compiled')
        second = self.commit('second')
        self.checkout('Dockerfile', destination, second)
        self.assertEqual((destination / 'source').read_text(), 'second')
        self.assertEqual(marker.read_text(), 'compiled')

    def test_both_checkouts_fail_for_invalid_or_unavailable_commits(self):
        for dockerfile in ('Dockerfile.base', 'Dockerfile'):
            for index, commit in enumerate(('', 'master', 'a' * 40)):
                with self.subTest(dockerfile=dockerfile, commit=commit):
                    destination = self.directory / f'{dockerfile}-{index}'
                    if dockerfile == 'Dockerfile':
                        self.checkout('Dockerfile.base', destination, self.first)
                    result = self.checkout(dockerfile, destination, commit, check=False)
                    self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
