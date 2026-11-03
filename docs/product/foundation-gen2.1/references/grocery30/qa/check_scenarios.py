"""Exercise a fictional single-household, single-shop service. No production code or network."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CASES = json.loads((ROOT / "inbox-scenarios.json").read_text(encoding="utf8"))


def total(goods, fee):
    return None if goods is None or fee is None else goods + fee


def check_checkout(case):
    before = total(case["before_goods"], case["before_fee"])
    after = total(case["after_goods"], case["after_fee"])
    change = None if before is None or after is None else after - before
    over = None if after is None else max(0, after - case["cap"])
    assert [before, after, change, over] == [
        case["before"], case["after"], case["change"], case["over_cap"]
    ], case["label"]


class Shop:
    def __init__(self):
        self.household = "example household"
        self.shop_id = "this pickup"
        self.members = {"Mia", "Alex", "Sam", "Jo"}
        self.adults = {"Mia", "Alex"}
        self.shopper = "Mia"
        self.epoch = 1
        self.shopper_at_epoch = {1: "Mia"}
        self.revision = 1
        self.phase = "open"
        self.requests = {}
        self.operations = {}
        self.basket = []
        self.separate_reports = []

    def perform(self, event):
        actor = event["actor"]
        op = event["op"]
        if actor not in self.members:
            return "access ended"
        if op in {"apply", "defer", "freeze", "place", "change_basis"}:
            if actor != self.shopper or event["epoch"] != self.epoch:
                return "shopper required"
        if op in {"transfer", "revoke"} and actor != "Mia":
            return "organizer required"
        if op in {"edit", "withdraw"} and event.get("owner", actor) != actor:
            return "request unavailable"
        if op == "report_order" and self.shopper_at_epoch.get(event["epoch"]) != actor:
            return "shopper required"

        # An authorized command can be replayed after its response is lost. Recheck
        # permissions first, but never execute a replay on a later basket revision.
        key = (self.household, actor, event["key"])
        fingerprint = (self.shop_id, json.dumps(event, sort_keys=True))
        if key in self.operations:
            saved, result = self.operations[key]
            return result if saved == fingerprint else "operation conflict"
        result = getattr(self, op)(event)
        self.operations[key] = (fingerprint, result)
        return result

    def send(self, event):
        # Client-chosen IDs are meaningful only inside the author's namespace.
        ident = (event["actor"], event["id"])
        if ident in self.requests:
            return "request ID in use"
        state = "pending" if self.phase == "open" else "next"
        self.requests[ident] = {"state": state, "revision": 1, "text": event["text"]}
        return state

    def edit(self, event):
        return self.update_own_request(event, "pending")

    def withdraw(self, event):
        return self.update_own_request(event, "withdrawn")

    def update_own_request(self, event, state):
        req = self.requests.get((event["actor"], event["id"]))
        if req is None:
            return "request unavailable"
        if req["state"] != "pending":
            return "follow-up required"
        if event["request_revision"] != req["revision"]:
            return "refresh request"
        req["state"] = state
        req["revision"] += 1
        if state == "pending":
            req["text"] = event["text"]
        return ("updated" if state == "pending" else "withdrawn")

    def apply(self, event):
        return self.decide(event, "added")

    def defer(self, event):
        return self.decide(event, "next")

    def decide(self, event, state):
        ident = (event["owner"], event["id"])
        req = self.requests.get(ident)
        if req is None:
            return "request unavailable"
        if self.phase != "open":
            return "checkout closed to edits"
        if req["state"] != "pending":
            return "already handled"
        if event["revision"] != self.revision or event["request_revision"] != req["revision"]:
            return "refresh preview"
        req["state"] = state
        req["revision"] += 1
        if state == "added":
            self.basket.append(ident)
            self.revision += 1
        return state

    def change_basis(self, event):
        if self.phase != "open" or event["revision"] != self.revision:
            return "refresh preview"
        # Represents an edit to cap, fee, quantity or another checkout input.
        self.revision += 1
        return "basis changed"

    def transfer(self, event):
        target = event["target"]
        if target not in self.adults or target not in self.members:
            return "eligible adult required"
        if event["epoch"] != self.epoch or event["revision"] != self.revision or self.phase == "placed":
            return "refresh handover"
        self.shopper = target
        self.epoch += 1
        self.shopper_at_epoch[self.epoch] = target
        return "transferred"

    def revoke(self, event):
        if event["target"] == self.shopper:
            return "transfer first"
        self.members.discard(event["target"])
        return "revoked"

    def freeze(self, event):
        if self.phase != "open" or event["revision"] != self.revision:
            return "refresh checkout"
        self.phase = "reviewing"
        self.revision += 1
        return "frozen"

    def place(self, event):
        if event["revision"] != self.revision or self.phase == "placed":
            return "refresh checkout"
        self.phase = "placed"
        self.revision += 1
        for req in self.requests.values():
            if req["state"] == "pending":
                req["state"] = "next"
                req["revision"] += 1
        return "placed"

    def report_order(self, event):
        # A previously authorized adult's external purchase is evidence. A stale
        # report cannot change the current shopper, basket, cutoff or queue.
        if event["epoch"] == self.epoch and event["revision"] == self.revision and self.phase != "placed":
            return self.place(event)
        self.separate_reports.append((event["actor"], event["epoch"], event["revision"]))
        return "separate report"

    def summary(self, results):
        return {
            "states": {f"{actor}/{rid}": req["state"] for (actor, rid), req in self.requests.items()},
            "basket": [f"{actor}/{rid}" for actor, rid in self.basket],
            "shopper": self.shopper,
            "epoch": self.epoch,
            "revision": self.revision,
            "phase": self.phase,
            "separate_reports": [list(record) for record in self.separate_reports],
            "results": results,
        }


for case in CASES["checkout"]:
    check_checkout(case)
for case in CASES["routing"]:
    shop = Shop()
    results = [shop.perform(event) for event in case["events"]]
    actual = shop.summary(results)
    assert actual == case["expected"], (case["label"], actual, case["expected"])

print(f"Passed {len(CASES['checkout'])} arithmetic and {len(CASES['routing'])} reference routing cases. Fixtures only.")

