from common import *
import sys
verify(); disk(); no_native()
record = json.loads((BASE / 'phase2/run.json').read_text())
assert record['status'] == 'completed'
products = json.loads((BASE / 'compiled-products.json').read_text())
assert tree(PRODUCTS) == products
out = BASE / 'inspection'; out.mkdir(exist_ok=False)
original = BASE / 'test.xcresult'; before = tree(original); assert before
write(out / 'original-before.json', before)
copy = out / 'test.xcresult'
subprocess.run(['/bin/cp', '-cR', str(original), str(copy)], check=True)
assert tree(copy) == before
selection = PROPOSAL / 'selectors.txt'
assert len(selection.read_text().splitlines()) == len(set(selection.read_text().splitlines())) == 43
shutil.copy2(selection, out / 'selectors.txt')
def run(command, filename):
    with (out / filename).open('x') as stdout, (out / (filename + '.stderr')).open('x') as stderr:
        return subprocess.run(command, cwd=CANONICAL, env=ENV, stdout=stdout, stderr=stderr, timeout=300).returncode
verification = {'nativeExit': record['nativeExit'], 'expectedCount': 43, 'scope': 'Model and production owner transport with confined fake engine; not actual AV/acoustic qualification'}
strict = 1
try:
    for kind in ['summary', 'tests']:
        assert run(['/usr/bin/xcrun', 'xcresulttool', 'get', 'test-results', kind, '--path', str(copy)], kind + '.json') == 0
    command = ['python3', 'scripts/check_ios_test_results.py', '--selectors', str(out / 'selectors.txt'), '--expected-count', '43',
               '--summary', str(out / 'summary.json'), '--tests', str(out / 'tests.json'), '--result-bundle', str(copy), '--test-log', str(BASE / 'phase2/native.log')]
    write(out / 'strict-command.json', command)
    strict = run(command, 'strict.txt')
    verification['strictExit'] = strict
except BaseException as error:
    verification.update(errorType=type(error).__name__, error=str(error))
finally:
    verification.update(originalUnchanged=tree(original) == before, compiledProductsUnchanged=tree(PRODUCTS) == products,
                        inspectedAtUTC=now(), checkerSHA256=sha(CANONICAL / 'scripts/check_ios_test_results.py'))
    try: verification['sourceAndPriorEvidenceUnchanged'] = verify()
    except BaseException as error: verification.update(sourceAndPriorEvidenceUnchanged=False, preservationError=str(error))
    write(out / 'verification.json', verification)
print(json.dumps(verification))
assert verification['originalUnchanged'] and verification['compiledProductsUnchanged'] and verification['sourceAndPriorEvidenceUnchanged']
sys.exit(strict or record['nativeExit'])
