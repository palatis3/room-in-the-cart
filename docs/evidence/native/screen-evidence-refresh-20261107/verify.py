from pathlib import Path
import hashlib, json, sys
here = Path(__file__).resolve().parent
repo = here.parents[3]
sys.path.insert(0, str(repo / "scripts"))
import check_swift_package_results as checker
for rel, expected in json.loads((here / "input-manifest.json").read_text()).items():
    assert hashlib.sha256((repo / rel).read_bytes()).hexdigest() == expected, rel
math = repo / "docs/evidence/native/acceptance-math-20261107"
policy = json.loads((repo / "scripts/swift_package_test_inventory.json").read_text())["packages"]["CoreDomain"]
log = (math / "core-domain.log").read_text()
assert checker.verify_package("CoreDomain", policy, (math / "CoreDomain.inventory.txt").read_text().splitlines(), log) == (171, 0)
outcomes = checker.test_outcomes(log)
report = json.loads((here / "supplement.json").read_text())
ledger = json.loads((repo / report["historical_ledger"]).read_text())
clauses = {c["clause_id"]: c for s in ledger["screens"] for c in s["clauses"]}
assert len(report["rows"]) == 9
assert len({r["clause_id"] for r in report["rows"]}) == 9
for row in report["rows"]:
    assert row["requirement"] == clauses[row["clause_id"]]["acceptance_outcome"]
    if row["current_assessment"] == "proven-in-scoped-calculation-run":
        assert outcomes[row["selector"]] == "passed"
        for event in row["execution_events"]:
            assert log.splitlines()[event["line"]-1] == event["text"]
        assert row["selector"].split("/")[-1] in (repo / row["source"]).read_text().splitlines()[row["source_line"]-1]
    else:
        receipt = json.loads((repo / row["evidence"]).read_text())
        assert receipt["strictExit"] == 0 and receipt["passed"] == 1 and receipt["runtimeWarnings"] == 0
for rel, expected in json.loads((here / "freeze.json").read_text()).items():
    assert hashlib.sha256((here / rel).read_bytes()).hexdigest() == expected, rel
print("Nine scoped clause bindings and 171-case package replay verified; no new tests executed.")
