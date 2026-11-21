"""Compare two recorded twelve-shopper walkthroughs using their shared decisions."""

import argparse
import csv
import json
from pathlib import Path
from statistics import mean

RUBRIC = Path(__file__).resolve().parents[1] / "docs/ci/shopper-criteria.csv"
WEIGHTS = {"O": 35, "E": 25, "C": 20, "A": 15, "R": 5}
SLOTS = tuple(f"{index:02}" for index in range(1, 13))


def load_trip(folder, domains):
    trip = json.loads((folder / "trip.json").read_text())
    cap = trip["cap"]
    if cap not in (None, 25, 49, 69) or (cap is not None and not trip.get("capReason")):
        raise ValueError(f"{folder}: invalid or unexplained consequence ceiling")
    ratings = {}
    for row in json.loads((folder / "ratings.json").read_text()):
        key = row["id"]
        if key not in domains or key in ratings or row["score"] not in (0, 25, 50, 75, 100):
            raise ValueError(f"{folder}: invalid or duplicated rating {key}")
        references = row.get("evidence")
        if not row.get("reason") or not isinstance(references, list) or not references or not all((folder / ref).is_file() for ref in references):
            raise ValueError(f"{folder}: missing evidence for rating {key}")
        ratings[key] = row["score"]
    return ratings, cap


def score(ratings, keys, domains, cap):
    groups = {domain: [ratings[key] for key in keys if domains[key] == domain] for domain in WEIGHTS}
    if len(keys) < 25 or any(len(group) < 2 for group in groups.values()):
        return None
    raw = sum(mean(group) * WEIGHTS[domain] / 100 for domain, group in groups.items())
    return min(raw, cap) if cap is not None else raw


def compare(before, after, domains, exclusions):
    results = []
    observations = {key: [] for key in domains}
    for slot in SLOTS:
        old, old_cap = load_trip(before / slot, domains)
        new, new_cap = load_trip(after / slot, domains)
        shared = old.keys() & new.keys()
        if not exclusions.get(slot, set()) <= shared:
            raise ValueError(f"{slot}: judge exclusion has no matching observations")
        shared -= exclusions.get(slot, set())
        results.append((slot, len(shared), score(old, shared, domains, old_cap),
                        score(new, shared, domains, new_cap), old_cap, new_cap))
        for key in shared:
            observations[key].append((slot, old[key], new[key]))
    return results, observations


def criterion_report(rubric, observations, csv_path=None):
    rows = []
    decreased = 0
    for key, criterion in rubric.items():
        cells = observations[key]
        lower = [slot for slot, old, new in cells if new < old]
        decreased += len(lower)
        rows.append({
            "id": key, "criterion": criterion["criterion"], "domain": criterion["domain"],
            "shared_observations": len(cells),
            "before_mean": round(mean(old for _, old, _ in cells), 2) if cells else None,
            "after_mean": round(mean(new for _, _, new in cells), 2) if cells else None,
            "improved_trips": " ".join(slot for slot, old, new in cells if new > old),
            "unchanged_trips": " ".join(slot for slot, old, new in cells if new == old),
            "lower_trips": " ".join(lower),
        })
    observed = sum(bool(row["shared_observations"]) for row in rows)
    print(f"Matched evidence for {observed}/{len(rows)} criteria; {decreased} individual ratings fell.")
    if csv_path:
        with csv_path.open("w", newline="", encoding="utf-8") as file:
            writer = csv.DictWriter(file, fieldnames=rows[0].keys())
            writer.writeheader()
            writer.writerows(rows)
    return decreased


def report(results, fail_on_decline):
    incomplete = False
    declines = []
    print("Journey    Shared     Before      After    Change")
    for slot, shared, earlier, later, old_cap, new_cap in results:
        worse_ceiling = (new_cap or 100) < (old_cap or 100)
        if earlier is None or later is None:
            if worse_ceiling:
                declines.append(slot)
            print(f"{slot:>7}    {shared:>6}    Insufficient comparable observations")
            incomplete = True
            continue
        print(f"{slot:>7}    {shared:>6}    {earlier:>7.2f}    {later:>7.2f}    {later-earlier:+.2f}")
        if earlier - later > 1e-9 or worse_ceiling:
            declines.append(slot)
    if incomplete:
        eligible = [row for row in results if row[2] is not None and row[3] is not None]
        if eligible:
            print(f"Eligible subset ({len(eligible)}/{len(results)} journeys): "
                  f"{mean(row[2] for row in eligible):.2f} -> {mean(row[3] for row in eligible):.2f}/100")
        if declines:
            print("Review lower scores or new consequence ceilings for " + ", ".join(declines))
        print("The full cohort needs more matched evidence.")
        return 2
    print(f"Equal-weight cohort: {mean(r[2] for r in results):.2f} -> {mean(r[3] for r in results):.2f}/100")
    if declines:
        print("Review lower scores or new consequence ceilings for " + ", ".join(declines))
    return int(fail_on_decline and bool(declines))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=Path)
    parser.add_argument("after", type=Path)
    parser.add_argument("--exclusions", type=Path, help="Judged pairs with shopper, criterion, reason and judge")
    parser.add_argument("--fail-on-decline", action="store_true", help="Return 1 if any eligible journey worsened")
    parser.add_argument("--criteria-csv", type=Path, help="Write all criteria and the individual trips that improved, held or declined")
    parser.add_argument("--fail-on-observed-decline", action="store_true",
                        help="Also return 1 if an individual matched criterion rating fell")
    args = parser.parse_args()
    with RUBRIC.open(newline="") as file:
        rubric = {int(row["id"]): row for row in csv.DictReader(file)}
    domains = {key: criterion["domain"] for key, criterion in rubric.items()}
    exclusions = {}
    if args.exclusions:
        for row in json.loads(args.exclusions.read_text()):
            slot = row["shopper"]
            if slot not in SLOTS or not row.get("reason") or not row.get("judge"):
                raise ValueError("A pair exclusion needs its shopper, judge and reason")
            exclusions.setdefault(slot, set()).add(row["criterion"])
    results, observations = compare(args.before, args.after, domains, exclusions)
    status = report(results, args.fail_on_decline or args.fail_on_observed_decline)
    decreased = criterion_report(rubric, observations, args.criteria_csv)
    return status or int(args.fail_on_observed_decline and decreased > 0)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise SystemExit(f"Could not compare shopper evidence: {error}")
