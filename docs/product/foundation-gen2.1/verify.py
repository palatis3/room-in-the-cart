"""Run from the extracted blueprint. Only Python stdlib and SQLite 3.38+ required."""
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parent
if sys.version_info < (3,13):
    raise SystemExit("Use the supported verifier runtime: Python 3.13+ with SQLite 3.38+.")
if not __debug__:
    raise SystemExit("Run without -O: reference checks require Python assertions.")


def load(name):
    return json.loads((ROOT / name).read_text(encoding="utf8"))


def coverage():
    features = (ROOT / "02-features.md").read_text(encoding="utf8")
    screens = (ROOT / "03-screens.md").read_text(encoding="utf8")
    ids = re.findall(r"^### ([DFPENAX]\d\d) ·", features, re.M)
    expected = {f"{k}{i:02}" for k, n in dict(D=16,F=9,P=8,E=10,N=7,A=3,X=6).items() for i in range(1,n+1)}
    assert set(ids) == expected and len(set(ids)) == len(ids)
    live = expected - {i for i in expected if i.startswith("X")} - {"E05"}
    assert len(live) == 52
    screen_ids = re.findall(r"^### (S\d\d) ·", screens, re.M)
    assert len(screen_ids) == 27 and set(screen_ids) == {f"S{i:02}" for i in range(1,28)}
    for block in re.split(r"^### [DFPENAX]\d\d ·", features, flags=re.M)[1:]:
        assert "**Accept when.**" in block and re.search(r"\bS\d\d\b", block)
        assert set(re.findall(r"\bS\d\d\b", block)) <= set(screen_ids)
    for doc in ROOT.glob("*.md"):
        for target in re.findall(r"\]\(([^)\n]+)\)", doc.read_text(encoding="utf8")):
            url = urlsplit(target)
            if url.scheme or not url.path:
                continue
            path = (doc.parent / unquote(url.path)).resolve()
            assert path.is_relative_to(ROOT) and path.exists(), (doc.name,target)
    for src in load("references/sources.json"):
        if "pack_copy" in src:
            assert hashlib.sha256((ROOT/src["pack_copy"]).read_bytes()).hexdigest()==src["sha256"]
    theme = load("contracts/theme.json")
    assert theme["light"]["accent"] == "#195848" and theme["dark"]["accent"] == "#91DBBB"
    assert theme["light"].keys() == theme["dark"].keys() and theme["min_hit_pt"]==44
    print("59 registered decisions, 52 launch requirements, 27 screens, local links, themes and source checksums verified.")


def schema():
    if sqlite3.sqlite_version_info < (3,38):
        raise RuntimeError("Use Python linked with SQLite 3.38+ (JSON functions and STRICT tables).")
    db = sqlite3.connect(":memory:")
    db.executescript((ROOT/"contracts/model.sql").read_text(encoding="utf8"))
    tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    for table in tables:
        db.execute(f'EXPLAIN INSERT INTO "{table}" DEFAULT VALUES')

    def row(table, **fields):
        names=", ".join(fields)
        marks=", ".join("?" for _ in fields)
        db.execute(f"INSERT INTO {table} ({names}) VALUES ({marks})", list(fields.values()))

    def must_reject(fn):
        try:
            fn()
        except sqlite3.IntegrityError:
            return
        raise AssertionError("A constraint expected to reject the write accepted it")

    zone="America/New_York"
    instant="2026-11-02T18:00:00Z"
    def owned(table, **fields):
        row(table,household_id="H",**fields)
    row("household", household_id="H",mode="service",display_name="Fixture",zone=zone)
    row("household", household_id="OTHER",mode="service",display_name="Other",zone=zone)
    for actor,kind in [("Mia","adult"),("Alex","adult"),("Sam","child")]:
        owned("member",member_id=actor,alias=actor,kind=kind,state="active")
        owned("device",device_id=actor+"-phone",member_id=actor)
    shop = dict(shop_id="S",shopper_id="Mia",currency="USD",cap_scope="whole",zone=zone)
    owned("shop",**shop)
    must_reject(lambda: row("shop",household_id="OTHER",**shop))
    must_reject(lambda: owned("shop",**(shop|{"shop_id":"bad","shopper_id":"Sam"})))
    revision = dict(shop_id="S",display_no=1,author_id="Mia",content_digest="fixture",snapshot_json="{}",committed_at=instant)
    owned("shop_revision",revision_id="base",**revision)
    owned("shop_head",head_id="head",shop_id="S",revision_id="base")
    owned("shop_line",line_id="line",shop_id="S",original_text="coffee",source_locale="en-US")
    owned("deferral",deferral_id="d",origin_shop_id="S",origin_revision_id="base",origin_line_ref="line",
          original_text="coffee",purpose="staple",state="deferred",updated_at=instant)
    db.execute("DELETE FROM shop_line WHERE household_id='H' AND line_id='line'")
    assert db.execute("SELECT original_text,state FROM deferral").fetchone()==("coffee","deferred")
    owned("proposal",proposal_id="p",shop_id="S",owner_id="Alex",kind="guest",state="submitted",created_at=instant)
    owned("proposal_revision",proposal_revision_id="pr1",shop_id="S",proposal_id="p",revision_no=1,
          base_revision_id="base",base_authority_epoch=1,editor_id="Alex",inputs_json="{}",effects_json="{}",reviewed_at=instant)
    op=dict(client_key="same-client-key",kind="proposal.apply",payload_digest="digest",committed_at=instant)
    owned("operation",operation_id="receipt-m",actor_id="Mia",device_id="Mia-phone",**op)
    owned("operation",operation_id="receipt-a",actor_id="Alex",device_id="Alex-phone",**op)
    for key in ("receipt-m","receipt-a"):
        owned("operation_response",operation_id=key,outcome_json="{}")
    must_reject(lambda: owned("operation",operation_id="again",actor_id="Alex",device_id="Alex-phone",**op))
    owned("shop_revision",revision_id="candidate",parent_id="base",**(revision|{"display_no":2}))
    apply = dict(application_id="accepted",shop_id="S",proposal_id="p",proposal_revision_id="pr1",
                 result_revision_id="candidate",applied_at=instant)
    must_reject(lambda: owned("proposal_application",shopper_id="Alex",operation_id="receipt-a",**apply))
    db.execute("UPDATE shop SET shopper_id='Alex',authority_epoch=2 WHERE household_id='H' AND shop_id='S'")
    must_reject(lambda: owned("proposal_application",shopper_id="Mia",operation_id="receipt-m",**apply))
    must_reject(lambda: owned("proposal_application",shopper_id="Alex",operation_id="receipt-a",**apply))
    # The result of an unresolved adjustment must not vanish silently from a sum of posted charges.
    ledger=dict(shop_id="S",kind="charge",currency="USD",basis="receipt",observed_at=instant)
    must_reject(lambda: owned("ledger_entry",entry_id="unknown",source_record_key="q",status="posted",signed_minor=None,**ledger))
    owned("ledger_entry",entry_id="known-zero",source_record_key="free",status="posted",signed_minor=0,**ledger)
    owned("ledger_entry",entry_id="pending",source_record_key="pending",status="pending",signed_minor=None,**ledger)
    # Restoring the same Apple purchase cannot make a second household an owner.
    row("member",household_id="OTHER",member_id="Mia",alias="Other adult",kind="adult",state="active")
    purchase=dict(environment="sandbox",bundle_id="test.example",original_transaction_ref="original")
    owned("apple_purchase_binding",purchaser_id="Mia",**purchase)
    row("apple_transaction_identity",transaction_ref="renewal",**purchase)
    grant=dict(entitlement_id="entitlement",purchaser_id="Mia",product_id="household.year",transaction_ref="renewal",state="active",**purchase)
    must_reject(lambda: row("entitlement",household_id="OTHER",**grant))
    owned("entitlement",**grant)
    must_reject(lambda: row("apple_purchase_binding",household_id="OTHER",purchaser_id="Mia",**purchase))
    assert not db.execute("PRAGMA foreign_key_check").fetchall()
    print(f"{len(tables)} reference tables created. FK wiring, tenant separation, shopper role, persistent deferral, scoped retry, stale proposal, settlement and purchase binding checks passed.")
    db.close()


def scenarios():
    for file in ["references/grocery28/qa/check-contract.py","references/grocery30/qa/check_scenarios.py"]:
        subprocess.run([sys.executable,"-B",str(ROOT/file)],check=True)
    cases=load("contracts/new-features.json")["cases"]
    assert len({r["id"] for r in cases})==len(cases)
    assert set(Counter(r["feature"] for r in cases))=={"A01","A02","A03"}
    cash=next(r for r in cases if r["id"]=="A03-cash")
    a,b=(cash["given"][k] for k in ("a","b"))
    totals=[x["goods_minor"]+x["fee_minor"] for x in (a,b)]
    trips=[v+x["trip_minor"] for v,x in zip(totals,(a,b))]
    result={"checkout_a":totals[0],"checkout_b":totals[1],"trip_inclusive_a":trips[0],"trip_inclusive_b":trips[1],
            "checkout_b_minus_a":totals[1]-totals[0],"trip_inclusive_b_minus_a":trips[1]-trips[0],
            "extra_minutes_b_minus_a":b["extra_minutes"]-a["extra_minutes"]}
    assert result==cash["expect"]
    print(f"{len(cases)} owner-addition acceptance vectors present. Two-store worked arithmetic verified. UI and service execution remain build gates.")


if __name__ == "__main__":
    coverage()
    experience = (ROOT / "11-experience-audit.md").read_text(encoding="utf8")
    presentation = experience.split("Settings, system permission prompts")[0]
    route_ids = [code for row in presentation.splitlines() if row.startswith("| ")
                 for code in re.findall(r"\bS\d{2}\b", row.split("|")[2])]
    assert Counter(route_ids) == Counter(f"S{i:02}" for i in range(1,28))
    schema()
    scenarios()
    subprocess.run([sys.executable, "-B", str(ROOT/"verify_gen2.py")], check=True)
    subprocess.run([sys.executable, "-B", str(ROOT/"verify_placement_sql.py")], check=True)
