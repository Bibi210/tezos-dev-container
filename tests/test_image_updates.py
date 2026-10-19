"""Exercise the updater with a fake Docker daemon, without deleting real images."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
DOCKER = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p = Path(os.environ['FAKE_DOCKER_STATE'])
s = json.loads(p.read_text())
a = sys.argv[1:]
if a[:2] == ['image', 'inspect']:
    image = s['current'] if a[-1].endswith(':latest') else a[-1]
    if image not in s['images']:
        sys.exit(1)
    print(image)
elif a == ['pull', 'ghcr.io/lthms/tezos-dev-container:latest']:
    if s.get('fail_pull'):
        sys.exit(1)
    s['current'] = s['next']
    if s['current'] not in s['images']:
        s['images'].append(s['current'])
elif a == ['image', 'ls', '--all', '--digests', '--no-trunc', '--format', '{{.ID}} {{.Repository}}']:
    if s.get('fail_list'):
        sys.exit(1)
    for image in s['images']:
        origin = s.get('repositories', {}).get(image, 'ghcr.io/lthms/tezos-dev-container')
        print(image, origin)
elif a[:2] == ['image', 'rm'] and len(a) == 3:
    s.setdefault('removals', []).append(a[2])
    p.write_text(json.dumps(s))
    if a[2] in s.get('blocked', []):
        sys.exit(1)
    s['images'].remove(a[2])
else:
    raise SystemExit('Unexpected Docker invocation: ' + repr(a))
p.write_text(json.dumps(s))
'''


class ImageUpdateTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        docker = self.root / 'docker'
        docker.write_text(DOCKER)
        docker.chmod(0o755)
        self.data = self.root / 'docker.json'
        self.env = {**os.environ, 'PATH': f'{self.root}:{os.environ["PATH"]}',
                    'FAKE_DOCKER_STATE': str(self.data),
                    'TEZOS_DEV_IMAGES_LOCK': str(self.root / 'lock')}
        self.save(current='sha256:old', next='sha256:new',
                  images=['sha256:old', 'sha256:unrelated'],
                  repositories={'sha256:unrelated': 'example.org/unrelated'})

    def save(self, **data):
        self.data.write_text(json.dumps(data))

    def read(self):
        return json.loads(self.data.read_text())

    def run_helper(self, mode, check=True):
        return subprocess.run(['bash', str(ROOT / 'scripts/tezos-dev-images'), mode],
                              env=self.env, capture_output=True, text=True, check=check)

    def test_pull_and_cleanup_are_separate(self):
        self.run_helper('pull')
        self.assertIn('sha256:old', self.read()['images'])
        self.run_helper('clean')
        self.assertEqual(self.read()['images'], ['sha256:unrelated', 'sha256:new'])

    def test_in_use_image_is_retried_after_multiple_updates(self):
        self.save(**{**self.read(), 'blocked': ['sha256:old']})
        self.run_helper('pull')
        self.run_helper('clean')
        self.assertIn('sha256:old', self.read()['images'])
        self.save(**{**self.read(), 'next': 'sha256:newer', 'blocked': []})
        self.run_helper('pull')
        self.run_helper('clean')
        self.assertEqual(self.read()['images'], ['sha256:unrelated', 'sha256:newer'])

    def test_failed_pull_preserves_current_image(self):
        self.save(**{**self.read(), 'fail_pull': True})
        self.assertNotEqual(self.run_helper('pull', check=False).returncode, 0)
        self.run_helper('clean')
        self.assertEqual(self.read()['images'], ['sha256:old', 'sha256:unrelated'])
        self.assertNotIn('removals', self.read())

    def test_unchanged_pull_does_not_delete_latest(self):
        self.save(**{**self.read(), 'next': 'sha256:old'})
        self.run_helper('pull')
        self.run_helper('pull')
        self.run_helper('clean')
        self.assertNotIn('removals', self.read())

    def test_missing_latest_prevents_cleanup(self):
        self.run_helper('pull')
        before = self.read()['images']
        self.save(**{**self.read(), 'current': 'missing'})
        self.run_helper('clean')
        self.assertEqual(self.read()['images'], before)
        self.assertNotIn('removals', self.read())

    def test_failed_inventory_deletes_nothing(self):
        self.run_helper('pull')
        before = self.read()['images']
        self.save(**{**self.read(), 'fail_list': True})
        self.assertNotEqual(self.run_helper('clean', check=False).returncode, 0)
        self.assertEqual(self.read()['images'], before)

    def test_manually_removed_images_need_no_bookkeeping(self):
        self.run_helper('pull')
        self.save(**{**self.read(), 'images': ['sha256:new', 'sha256:unrelated']})
        self.run_helper('clean')
        self.assertEqual(self.read()['images'], ['sha256:new', 'sha256:unrelated'])

    def test_first_pull_without_existing_image(self):
        self.save(**{**self.read(), 'current': 'missing', 'images': []})
        self.run_helper('pull')
        self.run_helper('clean')
        self.assertEqual(self.read()['images'], ['sha256:new'])

    def test_cleanup_discovers_previous_pulls_without_running_downloader(self):
        self.save(**{**self.read(), 'current': 'sha256:new',
                     'images': ['sha256:old', 'sha256:new', 'sha256:unrelated']})
        self.run_helper('clean')
        self.assertEqual(self.read()['images'], ['sha256:new', 'sha256:unrelated'])

    def test_base_and_similarly_named_repositories_are_preserved(self):
        self.save(**{**self.read(),
                     'images': ['sha256:old', 'sha256:base', 'sha256:other'],
                     'repositories': {
                         'sha256:base': 'ghcr.io/lthms/tezos-dev-base',
                         'sha256:other': 'ghcr.io/lthms/tezos-dev-container-other'}})
        self.run_helper('pull')
        self.run_helper('clean')
        self.assertEqual(self.read()['images'], ['sha256:base', 'sha256:other', 'sha256:new'])
