import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
SHA = 'a' * 40
CONFIG = yaml.safe_load((ROOT / 'bitrise.yml').read_text())


class BitriseNativeAppTests(unittest.TestCase):
    def test_one_pipeline_named_push_branches_and_no_duplicate_workflow_triggers(self):
        self.assertEqual(CONFIG['format_version'], '25')
        self.assertNotIn('trigger_map', CONFIG)
        self.assertEqual(set(CONFIG['pipelines']), {'app-pair'})
        pipeline = CONFIG['pipelines']['app-pair']
        self.assertEqual(pipeline['triggers'], {'push': [
            {'branch': 'main'}, {'branch': 'codex/dinner-shopping-integration'},
            {'branch': 'codex/first-version-followup'}]})
        self.assertEqual(pipeline['workflows'], {'compact-cooking': {}, 'large-tonight': {}})
        self.assertEqual(set(CONFIG['workflows']), set(pipeline['workflows']))
        for lane, workflow in CONFIG['workflows'].items():
            self.assertEqual(workflow, {'envs': [{'RITC_NATIVE_LANE': lane}],
                                        'steps': [{'bundle::native-app': {}}]})
        steps = CONFIG['step_bundles']['native-app']['steps']
        self.assertEqual(len(steps), 1)
        self.assertEqual(list(steps[0]), ['script@1.2.1'])
        self.assertEqual(steps[0]['script@1.2.1']['timeout'], 1800)
        text = (ROOT / 'bitrise.yml').read_text()
        for forbidden in ('activate-ssh-key', 'deploy-to', 'certificate-and-profile', 'bitrise-runner-',
                          'pull_request:', 'tag:', 'secrets:', 'sudo ', 'curl '):
            self.assertNotIn(forbidden, text)

    def test_disjoint_exact_existing_app_methods_and_local_result_gate(self):
        seen = set()
        for lane, count in [('compact-cooking', 3), ('large-tonight', 2)]:
            lines = (ROOT / f'scripts/fixtures/bitrise-native/{lane}.txt').read_text().splitlines()
            self.assertEqual(len(lines), count)
            self.assertEqual(len(set(lines)), count)
            self.assertTrue(seen.isdisjoint(lines)); seen.update(lines)
            for selector in lines:
                target, suite, method = selector.split('/')
                folder = 'UITests' if target == 'RoomInTheCartUITests' else 'Tests'
                source = ROOT / 'ios' / folder / (suite + '.swift')
                self.assertIn('func ' + method + '(', source.read_text())
        runner = (ROOT / 'scripts/run_bitrise_native_app.sh').read_text()
        self.assertIn('bash scripts/run_ios_test_shard.sh', runner)
        self.assertIn('scripts/check_built_app.py', runner)
        self.assertIn('-jobs 2', runner)
        self.assertNotIn('sudo ', runner)
        self.assertNotIn('upload', runner)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name); self.bin = self.path / 'bin'; self.bin.mkdir()
        (self.path / 'scripts/fixtures').mkdir(parents=True)
        shutil.copytree(ROOT / 'scripts/fixtures/bitrise-native', self.path / 'scripts/fixtures/bitrise-native')
        shutil.copy(ROOT / 'scripts/run_bitrise_native_app.sh', self.path / 'scripts')
        shutil.copy(ROOT / 'bitrise.yml', self.path)
        stub = '''#!PYTHON
import json,os,sys,subprocess,time
from pathlib import Path
name=Path(sys.argv[0]).name; args=sys.argv[1:]
with open(os.environ['CALLS'],'a') as f: f.write(json.dumps([name,*args])+'\\n')
if name=='git':
 if args==['rev-parse','HEAD']: print(os.environ['MOCK_HEAD'])
 elif args==['rev-parse','FETCH_HEAD']: print(os.environ['MOCK_HEAD'])
 elif args[:1]==['status']: print(os.environ.get('MOCK_DIRTY',''),end='')
elif name=='uname': print('arm64')
elif name=='xcode-select': print('/Applications/Reviewed.app/Contents/Developer')
elif name=='xcodebuild':
 if args==['-version']: print('Xcode 27.1\\nBuild version '+os.environ.get('MOCK_XCODE','27A9275'))
 else:
  if os.environ.get('CHECK_OVERLAP'):
   Path('build-started').touch()
   for _ in range(100):
    if Path('boot-started').exists(): break
    time.sleep(.02)
   else: sys.exit(9)
  sys.exit(int(os.environ.get('MOCK_BUILD_EXIT','0')))
elif name=='xcrun':
 if args==['simctl','list','runtimes','--json']:
  print(json.dumps({'runtimes':[{'identifier':'com.apple.CoreSimulator.SimRuntime.iOS-27-0',
      'isAvailable':True,'buildversion':os.environ.get('MOCK_RUNTIME','24A434')}]}))
 elif args[:2]==['simctl','create']: print('11111111-1111-4111-8111-111111111111')
elif name=='python3' and args[:1]==['scripts/boot_ios_simulator.py']:
 if os.environ.get('CHECK_OVERLAP'):
  Path('boot-started').touch()
  for _ in range(100):
   if Path('build-started').exists(): break
   time.sleep(.02)
  else: sys.exit(9)
  Path('boot-complete').touch()
 sys.exit(int(os.environ.get('MOCK_BOOT_EXIT','0')))
elif name=='python3' and args==['-']: sys.exit(subprocess.run([sys.executable,'-'],input=sys.stdin.read(),text=True).returncode)
elif name=='bash':
 if os.environ.get('CHECK_OVERLAP') and not Path('boot-complete').exists(): sys.exit(8)
 sys.exit(int(os.environ.get('MOCK_TEST_EXIT','0')))
'''.replace('PYTHON', str(Path(sys.executable).resolve()))
        for name in ('git', 'uname', 'xcode-select', 'xcodebuild', 'xcrun', 'python3', 'bash'):
            executable = self.bin / name; executable.write_text(stub); executable.chmod(0o755)
        self.env = {**os.environ, 'PATH': str(self.bin) + ':' + os.environ['PATH'],
                    'CALLS': str(self.path / 'calls.jsonl'), 'MOCK_HEAD': SHA,
                    'BITRISE_GIT_COMMIT': SHA, 'BITRISE_GIT_BRANCH': 'codex/first-version-followup',
                    'BITRISE_BUILD_SLUG': 'test-build', 'BITRISE_PULL_REQUEST': '',
                    'BITRISEIO_PULL_REQUEST_REPOSITORY_URL': ''}

    def run_lane(self, lane='compact-cooking', **changes):
        result = subprocess.run(['/bin/bash', 'scripts/run_bitrise_native_app.sh', lane],
                                cwd=self.path, env={**self.env, **changes}, text=True, capture_output=True)
        log = self.path / 'calls.jsonl'
        calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        return result, calls

    def test_both_lanes_use_exact_commit_distinct_devices_and_owned_cleanup(self):
        for lane, device, count in [('compact-cooking','iPhone-SE-3rd-generation',3),
                                     ('large-tonight','iPhone-17-Pro-Max',2)]:
            result, calls = self.run_lane(lane)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(['xcrun','simctl','create',f'RITC native {lane} test-build',
                           'com.apple.CoreSimulator.SimDeviceType.'+device,
                           'com.apple.CoreSimulator.SimRuntime.iOS-27-0'], calls)
            self.assertIn(['xcrun','simctl','delete','11111111-1111-4111-8111-111111111111'],calls)
            builds = [c for c in calls if c[0]=='xcodebuild' and 'build-for-testing' in c]
            self.assertEqual(len([s for s in builds[-1] if s.startswith('-only-testing:')]),count)
            self.assertIn(SHA, (self.path / '.build/bitrise-native-receipt.txt').read_text())

    def test_build_overlaps_boot_and_tests_require_both_to_succeed(self):
        result, calls = self.run_lane(CHECK_OVERLAP='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        build = next(c for c in calls if 'build-for-testing' in c)
        self.assertEqual(build[build.index('-destination') + 1], 'generic/platform=iOS Simulator')
        self.assertIn('ARCHS=arm64', build)
        self.assertIn(['bash', 'scripts/run_ios_test_shard.sh'], calls)
        for error in [{'MOCK_BOOT_EXIT': '7'}, {'MOCK_BUILD_EXIT': '65'}]:
            with self.subTest(error=error):
                (self.path / 'calls.jsonl').unlink()
                result, calls = self.run_lane(**error)
                self.assertEqual(result.returncode, int(next(iter(error.values()))))
                self.assertNotIn(['bash', 'scripts/run_ios_test_shard.sh'], calls)
                self.assertEqual(calls[-1][:3], ['xcrun', 'simctl', 'delete'])

    def test_rejects_wrong_commit_branch_pr_and_dirty_source_before_build(self):
        cases = [{'BITRISE_GIT_COMMIT':'main'}, {'MOCK_HEAD':'b'*40}, {'BITRISE_GIT_BRANCH':'outside'},
                 {'BITRISE_PULL_REQUEST':'42'}, {'BITRISEIO_PULL_REQUEST_REPOSITORY_URL':'https://example.com'},
                 {'MOCK_DIRTY':' M ios/App/RootView.swift'}]
        for changes in cases:
            with self.subTest(changes=changes):
                result,calls=self.run_lane(**changes)
                self.assertNotEqual(result.returncode,0)
                self.assertFalse(any(c[0]=='xcodebuild' and 'build-for-testing' in c for c in calls))

    def test_wrong_toolchain_fails_before_device_or_build(self):
        result,calls=self.run_lane(MOCK_XCODE='next-unreviewed')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(any(c[0]=='xcrun' for c in calls))

    def test_wrong_runtime_fails_before_device_or_build(self):
        result,calls=self.run_lane(MOCK_RUNTIME='unreviewed')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(any(c[:3]==['xcrun','simctl','create'] for c in calls))
        self.assertFalse(any(c[0]=='xcodebuild' and 'build-for-testing' in c for c in calls))

    def test_build_and_result_failure_still_delete_only_owned_device(self):
        for changes in [{'MOCK_BUILD_EXIT':'65'}, {'MOCK_TEST_EXIT':'1'}]:
            with self.subTest(changes=changes):
                result,calls=self.run_lane(**changes)
                self.assertNotEqual(result.returncode,0)
                self.assertEqual(calls[-1], ['xcrun','simctl','delete','11111111-1111-4111-8111-111111111111'])
                self.assertFalse(any('all' in c for c in calls))

    def test_checkout_uses_event_sha_and_only_anonymous_first_party_fetch(self):
        content = CONFIG['step_bundles']['native-app']['steps'][0]['script@1.2.1']['inputs'][0]['content']
        env = {**self.env, 'BITRISE_SOURCE_DIR':str(self.path), 'RITC_NATIVE_LANE':'compact-cooking'}
        result = subprocess.run(['/bin/bash','-c',content],cwd=self.path,env=env,text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        calls=[json.loads(line) for line in (self.path/'calls.jsonl').read_text().splitlines()]
        self.assertIn(['git','-c','credential.helper=','fetch','--quiet','--no-tags','--depth=1',
                       'https://github.com/palatis3/room-in-the-cart.git',SHA],calls)
        self.assertNotIn('refs/heads/', content)
        env['MOCK_HEAD']='b'*40
        result=subprocess.run(['/bin/bash','-c',content],cwd=self.path,env=env,text=True,capture_output=True)
        self.assertNotEqual(result.returncode,0)


if __name__ == '__main__': unittest.main()
