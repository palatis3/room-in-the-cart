"""Read only the isolated simulator test workspace at each named XCTest checkpoint."""

import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import time


CHECKPOINTS = [
    "N06 baseline", "N06 picker cancelled", "N06 damaged rejected",
    "N06 review cancelled", "N06 first applied", "N06 identical reopened",
]


def snapshot(device):
    container = subprocess.check_output(
        ["xcrun", "simctl", "get_app_container", device, "dev.roominthecart.app.debug", "data"], text=True
    ).strip()
    workspace = Path(container) / "Library/Application Support/UITestWorkspace"
    db = sqlite3.connect((workspace / "local.sqlite").as_uri() + "?mode=ro", uri=True)
    try:
        rows = db.execute("""
            SELECT c.id, c.head_revision, r.revision, r.title, r.envelope, r.saved_at
            FROM comparisons c JOIN comparison_revisions r ON r.comparison_id = c.id
            ORDER BY c.id, r.revision
        """).fetchall()
    finally:
        db.close()
    if len(rows) != 1 or rows[0][3] != "Later market oats":
        raise ValueError("Expected one revision of the live comparison")
    record_id, head, revision, title, envelope, saved = rows[0]
    entry = [record_id, head, revision, title, hashlib.sha256(envelope).hexdigest(), saved]
    manifest = workspace / "Records/recovery-v1.json"
    data = manifest.read_bytes() if manifest.exists() else None
    return {
        "comparisonRows": 1,
        "comparisonSHA256": hashlib.sha256(json.dumps([entry]).encode()).hexdigest(),
        "recoveredRows": len(json.loads(data)["records"]) if data else 0,
        "registrySHA256": hashlib.sha256(data).hexdigest() if data else None,
    }


def check(device, log, output):
    results = {}
    for name in CHECKPOINTS:
        while True:
            text = log.read_text(errors="replace") if log.exists() else ""
            if name in text:
                if any(later in text for later in CHECKPOINTS[CHECKPOINTS.index(name) + 1:]):
                    raise ValueError(f"Missed the live checkpoint {name}")
                break
            if "** TEST FAILED **" in text or "** TEST SUCCEEDED **" in text:
                raise ValueError(f"Test ended before {name}")
            time.sleep(0.5)
        results[name] = snapshot(device)
        output.write_text(json.dumps(results, indent=2) + "\n")
    if len({result["comparisonSHA256"] for result in results.values()}) != 1:
        raise ValueError("The live comparison changed during recovery")
    if [result["recoveredRows"] for result in results.values()] != [0, 0, 0, 0, 1, 1]:
        raise ValueError("Unexpected recovered-copy count")
    if results[CHECKPOINTS[-2]]["registrySHA256"] != results[CHECKPOINTS[-1]]["registrySHA256"]:
        raise ValueError("Reimport changed the saved recovery manifest")


if __name__ == "__main__":
    check(sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3]))
