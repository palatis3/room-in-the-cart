"""Offline shell controls: every native/database executable is a local stub."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
STUB = r'''#!/usr/bin/env python3
import os, pathlib, sys
name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
if name == 'node':
    if args == ['--version']: print('stub-node')
    elif '--input-type=module' in args: print('54321')
    else:
        state=pathlib.Path(os.environ['RITC_NATIVE_WIRE_STATE'])
        pathlib.Path(os.environ['TEST_STATE_RECORD']).write_text(str(state))
        (state/'journal-fixture').mkdir()
        (state/'journal-fixture'/'retained-journal').write_text('synthetic journal')
        (state/'tls-key.pem').write_text('PRIVATE-KEY-MARKER')
        print('stub integration output')
        sys.exit(int(os.environ.get('TEST_CASE_EXIT','0')))
elif name == 'initdb':
    path=pathlib.Path(args[args.index('-D')+1]);path.mkdir()
    (path/'database-marker').write_text('synthetic database')
elif name == 'pg_ctl':
    path=pathlib.Path(args[args.index('-D')+1]);pid=path/'postmaster.pid'
    if 'start' in args:
        pid.write_text('123')
        pathlib.Path(args[args.index('-l')+1]).write_text('PRIVATE-SQL-MARKER')
    elif 'stop' in args:
        if os.environ.get('TEST_STOP_FAIL') == '1': sys.exit(1)
        pid.unlink()
elif name == 'swift' and args and args[0] == 'build':
    print('stub build output')
    sys.exit(int(os.environ.get('TEST_BUILD_EXIT','0')))
else: print('stub-'+name)
'''


class NativeWireCustodyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root/'scripts').mkdir()
        shutil.copy2(ROOT/'scripts/run_ios_native_wire.sh', self.root/'scripts/run_ios_native_wire.sh')
        self.bin = self.root/'bin'; self.bin.mkdir()
        for name in ['xcodebuild', 'swift', 'node', 'postgres', 'openssl', 'initdb', 'pg_ctl', 'createdb']:
            path=self.bin/name; path.write_text(STUB); path.chmod(0o755)
        self.private=self.root/'private';self.private.mkdir()
        self.env={**os.environ, 'PATH':str(self.bin)+os.pathsep+os.environ['PATH'],
                  'TMPDIR':str(self.private), 'TEST_STATE_RECORD':str(self.root/'state-path')}

    def run_wrapper(self, **env):
        result=subprocess.run(['bash', str(self.root/'scripts/run_ios_native_wire.sh')],
                              env={**self.env, **env}, capture_output=True, text=True, timeout=15)
        attempts=sorted((self.root/'.build/native-wire-results').glob('attempt.*'))
        return result, attempts

    def test_success_cleans_private_state_and_attempts_never_overwrite(self):
        first, attempts=self.run_wrapper();self.assertEqual(first.returncode,0,first.stderr)
        old={str(p.relative_to(attempts[0])):p.read_bytes() for p in attempts[0].rglob('*') if p.is_file()}
        self.assertFalse(Path((self.root/'state-path').read_text()).exists())
        second, attempts=self.run_wrapper();self.assertEqual(second.returncode,0,second.stderr)
        self.assertEqual(len(attempts),2)
        original=next(p for p in attempts if all((p/k).read_bytes()==v for k,v in old.items()))
        self.assertFalse(json.loads((original/'cleanup.json').read_text())['privateStateRetained'])

    def test_failure_stops_and_preserves_database_journal_outside_public_results(self):
        result, attempts=self.run_wrapper(TEST_CASE_EXIT='7')
        self.assertEqual(result.returncode,7,result.stderr)
        state=Path((self.root/'state-path').read_text())
        self.assertEqual(state.stat().st_mode & 0o777,0o700)
        self.assertFalse((state/'postgres/postmaster.pid').exists())
        self.assertTrue((state/'postgres/database-marker').is_file())
        self.assertTrue((state/'journal-fixture/retained-journal').is_file())
        self.assertEqual((state/'custody.json').stat().st_mode & 0o777,0o600)
        receipt=json.loads((attempts[0]/'cleanup.json').read_text())
        self.assertTrue(receipt['privateStateRetained']);self.assertTrue(receipt['postgresStopped'])
        self.assertIn('ephemeral',receipt['retention'])
        public=b''.join(p.read_bytes() for p in attempts[0].rglob('*') if p.is_file())
        self.assertNotIn(b'PRIVATE-',public)
        self.assertIn(b'stub integration output',public)

    def test_stop_failure_is_fatal_and_never_deletes_live_state(self):
        result, attempts=self.run_wrapper(TEST_STOP_FAIL='1')
        self.assertEqual(result.returncode,1)
        state=Path((self.root/'state-path').read_text())
        self.assertTrue((state/'postgres/postmaster.pid').exists())
        self.assertFalse(json.loads((attempts[0]/'cleanup.json').read_text())['postgresStopped'])

    def test_build_failure_is_preserved_without_database_start(self):
        result, attempts=self.run_wrapper(TEST_BUILD_EXIT='9')
        self.assertEqual(result.returncode,9,result.stderr)
        self.assertFalse((self.root/'state-path').exists())
        self.assertIn('stub build output',(attempts[0]/'swift-build.log').read_text())
        self.assertTrue(json.loads((attempts[0]/'cleanup.json').read_text())['privateStateRetained'])

    def test_public_temp_root_is_rejected_before_private_material(self):
        public=self.root/'.build/native-wire-results';public.mkdir(parents=True)
        result,_=self.run_wrapper(TMPDIR=str(public))
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(list(public.rglob('custody.json')))
        self.assertFalse((self.root/'state-path').exists())


if __name__ == '__main__':
    unittest.main()
