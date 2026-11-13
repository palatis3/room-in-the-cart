from common import *
import signal, sys, time
phase = sys.argv[1]
assert phase in ['phase1', 'phase2']
verify(); disk(); no_native()
commands = json.loads((BASE / 'commands.json').read_text())
command = commands[phase]['command']
result = BASE / ('build.xcresult' if phase == 'phase1' else 'test.xcresult')
assert not result.exists()
out = BASE / phase; out.mkdir(exist_ok=False)
record = {'status': 'preparing', 'phase': phase, 'startedAtUTC': now(), 'command': command,
          'sourceManifestSHA256': sha(PROPOSAL / 'isolated-ios-candidate-manifest.json'),
          'expectedCount': 43 if phase == 'phase2' else None, 'cwd': str(ROOT), 'outerLimitSeconds': 2400}
write(out / 'run.json', record)
process = None; exit_code = 1
try:
    record['toolchain'] = toolchain()
    if phase == 'phase1':
        assert tree(PRODUCTS) == json.loads((BASE / 'r4-preservation.json').read_text())['products']
    else:
        build = json.loads((BASE / 'phase1/run.json').read_text())
        assert build['status'] == 'completed' and build['nativeExit'] == 0 and build['sourceUnchanged'] and 'stopReason' not in build
        build_manifest = json.loads((BASE / 'compiled-products.json').read_text())
        assert tree(PRODUCTS) == build_manifest
        build_evidence = {'result': tree(BASE / 'build.xcresult'), 'logSHA256': sha(BASE / 'phase1/native.log'), 'runSHA256': sha(BASE / 'phase1/run.json')}
        assert build_evidence['result']; write(out / 'build-evidence-before.json', build_evidence)
        record['runtime'] = runtime()
    write(out / 'run.json', record)
    started = time.monotonic()
    with (out / 'native.log').open('xb') as log:
        process = subprocess.Popen(command, cwd=ROOT, env=ENV, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        record.update(status='running', pid=process.pid); write(out / 'run.json', record)
        while process.poll() is None:
            time.sleep(1)
            reason = 'reservedDiskFloor' if shutil.disk_usage(BASE).free < FLOOR else 'outerWatchdog' if time.monotonic() - started > 2400 else None
            if reason:
                record['stopReason'] = reason; os.killpg(process.pid, signal.SIGTERM)
                try: process.wait(timeout=15)
                except subprocess.TimeoutExpired: os.killpg(process.pid, signal.SIGKILL); process.wait(timeout=15)
                break
        record['nativeExit'] = process.wait()
    record.update(sourceUnchanged=verify(), priorEvidenceUnchanged=preserved())
    if phase == 'phase1':
        write(BASE / 'compiled-products.json', tree(PRODUCTS))
    else:
        record['compiledProductsUnchanged'] = tree(PRODUCTS) == build_manifest
        record['buildEvidenceUnchanged'] = tree(BASE / 'build.xcresult') == build_evidence['result'] and sha(BASE / 'phase1/native.log') == build_evidence['logSHA256'] and sha(BASE / 'phase1/run.json') == build_evidence['runSHA256']
        assert record['compiledProductsUnchanged'] and record['buildEvidenceUnchanged']
    record.update(status='completed', finishedAtUTC=now())
    exit_code = record['nativeExit'] or (1 if 'stopReason' in record else 0)
except BaseException as error:
    record.update(status='failed', errorType=type(error).__name__, error=str(error), finishedAtUTC=now())
finally:
    if process is not None and process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try: process.wait(timeout=15)
        except subprocess.TimeoutExpired: os.killpg(process.pid, signal.SIGKILL); process.wait(timeout=15)
    write(out / 'run.json', record)
print(json.dumps({key: value for key, value in record.items() if key not in ['command', 'toolchain']}))
sys.exit(exit_code)
