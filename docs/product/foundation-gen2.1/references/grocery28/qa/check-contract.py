"""Verify conceptual fixture arithmetic, timelines, privacy projection and identity."""
from datetime import datetime
from pathlib import Path
import json

contract = json.loads((Path(__file__).resolve().parents[1] / "schema-contract.json").read_text(encoding="utf-8-sig"))
fixtures = contract["fixtures"]
trace = fixtures["shop_B_revision_and_order"]["events"]
base, copy, order, revised, amendment, cutoff, rejection, sent, reply = trace
assert [e["at"] for e in trace] == sorted(e["at"] for e in trace)
assert revised["parent"] == base["revision"] and revised["display"] == base["display"] + 1
assert base["expected_cents"] + revised["extra_pack_cents"] - revised["deferred_water_cents"] == revised["expected_cents"] == 3720
assert revised["wrap_packs"] == amendment["proposed_packs"] == 2
assert {e["confirmed_packs"] for e in [order, amendment, cutoff, rejection]} == {1}
hours = (datetime.fromisoformat(cutoff["pickup"]) - datetime.fromisoformat(amendment["deadline"])).total_seconds() / 3600
assert cutoff["at"] == amendment["deadline"] and hours == 24
assert cutoff["fill"] is None and cutoff["posted_cents"] is None
assert copy["actual"] is None and sent["actual"] is None and not any(e["acknowledged"] for e in [copy, sent])
assert sent["sender_reported_baseline_for_helper_A"] == "R2M" and sent["recipient_acknowledged_baseline_for_helper_A"] is None
assert reply["recipient_acknowledged_baseline_for_helper_A"] == sent["revision"] and reply["recipient_acknowledged_baseline_for_helper_B"] is None
guest_shop = fixtures["shop_B_revision_and_order"]
assert datetime.fromisoformat(cutoff["pickup"]).strftime("%A %Y-%m-%d %H:%M") == "Thursday 2026-11-05 17:00"
assert (datetime.fromisoformat(guest_shop["pickup_end"]) - datetime.fromisoformat(cutoff["pickup"])).total_seconds() == 3600
assert datetime.fromisoformat(guest_shop["guest_meal_date"]).strftime("%A %Y-%m-%d") == "Wednesday 2026-11-11"
assert fixtures["shop_A_fill"]["pickup_at"] == "2026-11-03T11:00:00-05:00"
fill = fixtures["shop_A_fill"]
received = fill["received_packs"] * fixtures["common"]["wraps_per_pack"]
previous_id = None
for observation in fill["observations"]:
    remaining = observation["usable"]
    assert 0 <= remaining <= received and observation["supersedes"] == previous_id
    for need, actual, short in zip(fill["needs"], observation["allocated"], observation["short"], strict=True):
        allocated = min(need["units"], remaining)
        assert allocated == actual and need["units"] - allocated == short
        remaining -= allocated
    assert remaining == 0
    previous_id = observation["id"]
posting = fixtures["posting_alternatives"]
for idx, case in enumerate(["net_charge", "charge_and_credit", "pending_credit"]):
    movements = {}
    for source_id, state, cents in posting[case]:
        if source_id in movements:
            assert movements[source_id] == (state, cents)
        movements[source_id] = (state, cents)
    assert sum(c for state, c in movements.values() if state == "posted") == posting["expected_paid_to_date"][idx]
    assert all(state != "pending" for state, _ in movements.values()) == posting["expected_final_known"][idx]
imports = fixtures["import"]
local = {r[1]: r for r in imports["local_revisions"]}
file = imports["helper_file"]
projection = set(file) - {"instructions"}
for row in file["instructions"]:
    projection.update("instructions[]." + field for field in row)
assert projection == set(contract["export_policy"]["helper_default_allowlist"])
assert "budget_cents" not in projection
imported_keys = set()
for attempt in range(2):
    identity = tuple(file[k] for k in ["origin_namespace", "shop_id", "source_revision_id", "projection_id", "payload_digest"])
    if identity not in imported_keys:
        local[file["source_revision_id"]] = [file[k] for k in ["shop_id", "source_revision_id", "parent_revision_id", "display_number"]]
        imported_keys.add(identity)
for r in imports["old_backup"]["revisions"]:
    if r[1] in local:
        assert local[r[1]] == r
    local.setdefault(r[1], r)
assert len(imported_keys) == 1 and set(local) == set(imports["expected_after_import_retry_and_recovery"])
assert local["R2M"][2:] == local["R2A"][2:] and imports["current_local_revision"] == "R2M"
print("Passed lineage, 24-hour cutoff, handoff evidence, price delta, corrected allocation, three ledger histories, helper allowlist, retry, sibling and recovery fixtures.")
