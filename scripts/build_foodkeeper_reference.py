#!/usr/bin/env python3
"""Build the offline subset from the four pinned official FoodKeeper responses."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path

HASHES = {
    "en": "037df0d301126acd8a48824506f04d49d8be1a1144b81fa69e4170228dc2e91a",
    "es": "2a25209edc1d578f1f0002a0a896c54c26611a4d986c46ebcdc156554190687b",
    "web-en": "5fe0c3cf7d4e5ced69325b519ae92e8b9b21dfe33d88b6fe2bb4e8dc52ed4192",
    "web-es": "d1f0bf4f28395c9f3c86f119685ffacfc79c3d97c6bf395bead203e62a9ce2c8",
}
CONTEXTS = {
    "Pantry": "pantry", "DOP_Pantry": "from_date_of_purchase_pantry",
    "Pantry_After_Opening": "pantry_after_opening", "Refrigerate": "refrigerate",
    "DOP_Refrigerate": "from_date_of_purchase_refrigerate",
    "Refrigerate_After_Opening": "refrigerate_after_opening",
    "Refrigerate_After_Thawing": "refrigerate_after_thawing", "Freeze": "freeze",
    "DOP_Freeze": "from_date_of_purchase_freeze",
}
UNITS = {
    "Days": ("Días", "Day", "Día"), "Weeks": ("Semanas", "Week", "Semana"),
    "Months": ("Meses", "Month", "Mes"), "Years": ("Años", "Year", "Año"), "Hours": ("Horas", "Hour", "Hora"),
}
WORDS = {
    "Not Recommended": {"No Recomendado"}, "When Ripe": {"Cuando Madure"},
    "Indefinitely": {"Indefinido", "Indefinidamente"},
    "Package use-by date": {"Fecha de Uso (Use by date)", "Fecha de Uso", "Fecha de Uso de Empaque",
                            "Fecha de consumir hasta día  (Use by date)", "Fecha de consumir hasta el día (Use by date)"},
}
OUTPUT = Path(__file__).resolve().parents[1] / "ios/Packages/CoreDomain/Sources/CoreDomain/Resources/FoodKeeper-v128.json"

def indexed(rows, id_key):
    result = {}
    for row in rows:
        key = int(row[id_key])
        if key != row[id_key] or key in result:
            raise ValueError(f"Invalid or duplicate ID {row[id_key]}")
        result[key] = row
    return result

def flattened(rows):
    result = []
    for cells in rows:
        row = {}
        for cell in cells:
            if len(cell) != 1 or cell.keys() & row.keys():
                raise ValueError("Ambiguous spreadsheet row")
            row.update(cell)
        result.append(row)
    return result

def duration(rows, prefix, display):
    bounds = [(r.get(prefix + "_Min"), r.get(prefix + "_Max")) for r in rows]
    en, es = (r.get(prefix + "_Metric") for r in rows)
    if not any(display) or not all(display):
        return None
    if en in WORDS and es in WORDS[en] and bounds == [(None, None), (None, None)] and display == [en, es]:
        return {"display": display}
    unit = "Years" if en == "Year" else en
    if unit not in UNITS or not isinstance(es, str) or es.casefold() != UNITS[unit][0].casefold() or bounds[0] != bounds[1]:
        return None
    low, high = bounds[0]
    if not all(isinstance(x, (int,float)) and 0 < x <= 1000 and int(x) == x for x in [low, high]) or low > high:
        return None
    low, high = int(low), int(high)
    plural_es, one_en, one_es = UNITS[unit]
    numbers = str(low) if low == high else f"{low} - {high}"
    expected = [f"{numbers} {unit if high != 1 else one_en}", f"{numbers} {plural_es if high != 1 else one_es}"]
    if any(a.casefold() != b.casefold() for a,b in zip(expected, display)):
        return None
    return {"display": expected, "minimum": low, "maximum": high, "unit": unit.lower()}

def generate(source):
    data = {}
    for name, digest in HASHES.items():
        raw = (source / (name + ".json")).read_bytes()
        if hashlib.sha256(raw).hexdigest() != digest:
            raise ValueError(f"Unexpected source hash for {name}")
        data[name] = json.loads(raw)
    raw, categories, web = [], [], []
    for locale in ("en", "es"):
        sheets = {s["name"]:flattened(s["data"]) for s in data[locale]["sheets"]}
        current = [v for v in sheets["Version"] if v.get("Current_Version") == "Yes"]
        if len(current) != 1 or current[0]["Data_Version_Number"] != 128 or current[0]["Modified_Date"] != "09-06-2018":
            raise ValueError("Unexpected publisher version")
        raw.append(indexed(sheets["Product"], "ID"))
        categories.append(indexed(sheets["Category"], "ID"))
        web.append(indexed(data["web-"+locale]["product_data"], "id"))
    products = []
    counts = Counter()
    for key in sorted(raw[0].keys() & raw[1].keys() & web[0].keys() & web[1].keys()):
        rows, displays = [r[key] for r in raw], [w[key] for w in web]
        cid = int(rows[0]["Category_ID"])
        if rows[1]["Category_ID"] != cid:
            counts["category_mismatch"] += 1
            continue
        ids = ["category_id", "name", "name_subtitle"]
        if any([r["Category_ID"], r["Name"], r.get("Name_subtitle")] != [w.get(k) for k in ids] for r,w in zip(rows, displays)):
            raise ValueError(f"Publisher product identity disagreement for {key}")
        names = [", ".join(str(v).strip() for v in [r["Name"], r.get("Name_subtitle")] if v) for r in rows]
        category = [" · ".join(c[k].strip() for k in ("Category_Name","Subcategory_Name") if c.get(k)) for c in (d[cid] for d in categories)]
        guidance = {}
        uncertain = False
        for prefix, field in CONTEXTS.items():
            tips = next((k for r in rows for k in r if k.lower() == prefix.lower()+"_tips"), None)
            notes = [r.get(tips) or "" for r in rows]
            labels = [w.get(field+"_output_display_only") for w in displays]
            rule = duration(rows, prefix, labels)
            has_input = any(r.get(prefix+s) is not None for r in rows for s in ["_Min","_Max","_Metric"])
            if has_input and rule is None:
                uncertain = True
                counts["ambiguous_or_unmatched_fields"] += 1
            if bool(notes[0]) != bool(notes[1]):
                uncertain = True
                counts["unpaired_note"] += 1
                # A contextual qualification missing in one language cannot support a shared rule.
                continue
            if rule is None and not any(notes):
                continue
            rule = rule or {}
            if any(notes):
                rule["notes"] = notes
            guidance[field] = rule
        if guidance:
            # Preserve conditional text as reference only. Never derive dates through unchecked qualifiers.
            dateable = not uncertain and not any(
                "notes" in rule or rule.get("display", [""])[0] == "Package use-by date"
                for rule in guidance.values()
            )
            products.append({"id":key, "names":names, "category":category, "rules":guidance, "dateable":dateable})
    # Identical visible variants within either language cannot be selected reliably.
    labels = [Counter((p["names"][i].casefold(), p["category"][i].casefold()) for p in products) for i in range(2)]
    unique = [p for p in products if all(labels[i][(p["names"][i].casefold(), p["category"][i].casefold())] == 1 for i in range(2))]
    counts["unresolved_variant_names"] = len(products) - len(unique)
    counts["matched_period_or_publisher_instruction"] = sum(
        1 for product in unique for rule in product["rules"].values() if rule.get("display")
    )
    return {"version":128,"products":unique}, counts

if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Directory containing the four verified source response bodies")
    parser.add_argument("--check", action="store_true")
    args=parser.parse_args()
    bundle, counts=generate(args.source)
    encoded=json.dumps(bundle,ensure_ascii=False,separators=(",",":")).encode()+b"\n"
    if args.check:
        if OUTPUT.read_bytes() != encoded:
            raise SystemExit("Bundled data differs from publisher inputs")
    else:
        OUTPUT.write_bytes(encoded)
    print(f"{len(bundle['products'])} products, {len(encoded)} bytes, {dict(counts)}")
