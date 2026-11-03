from pathlib import Path
import json

evidence = Path(__file__).resolve().parent
before = json.loads((evidence / 'state-before-dump.json').read_text())
after = json.loads((evidence / 'state-after-restore.json').read_text())
for key in ('tableData', 'schema', 'schemaDefinitions', 'semantic', 'permissions', 'currentSchemaRuntime'):
    assert before[key] == after[key], f'Restore mismatch: {key}'
print(json.dumps({'passed': True, 'tables': len(before['tableData']), 'rows': sum(t['rows'] for t in before['tableData'])}))
