"""Fresh SQLite reference checks for Foundation 2.1 placement and list contracts."""
from pathlib import Path
import sqlite3

ROOT = Path(__file__).resolve().parent
NOW = "2026-11-02T18:00:00Z"


def verify():
    db = sqlite3.connect(":memory:", isolation_level=None)
    db.executescript((ROOT / "contracts/model.sql").read_text(encoding="utf8"))
    run = db.execute

    def add(table, **fields):
        fields = {"household_id": "H", **fields}
        run(f"INSERT INTO {table} ({','.join(fields)}) VALUES ({','.join('?' for _ in fields)})",
            tuple(fields.values()))

    def reject(action):
        try:
            action()
        except sqlite3.IntegrityError:
            return
        raise AssertionError("Expected integrity constraint failure")

    add("household", mode="local", display_name="Test", zone="UTC")
    add("member", member_id="adult", alias="Adult", kind="adult", state="active")
    for shop, currency in [("main", "USD"), ("other", "CAD")]:
        add("shop", shop_id=shop, currency=currency, shopper_id="adult", cap_scope="whole", zone="UTC")
        add("period_budget", period_id=currency, currency=currency, owner_id="adult",
            start_local_date="2026-11-01", end_local_date="2026-11-30")
    reservation = dict(reservation_id="r", period_id="USD", shop_id="main", expected_minor=1200)
    reject(lambda: add("period_reservation", **reservation, currency="CAD"))
    reject(lambda: add("period_reservation", **{**reservation, "shop_id": "other"}, currency="USD"))
    add("period_reservation", **reservation, currency="USD")
    for sql in ["UPDATE period_reservation SET shop_id='other'",
                "UPDATE period_reservation SET period_id='CAD'",
                "UPDATE period_reservation SET currency='CAD'",
                "UPDATE shop SET currency='CAD' WHERE shop_id='main'",
                "UPDATE period_budget SET currency='CAD' WHERE period_id='USD'"]:
        reject(lambda: run(sql))
    run("UPDATE period_reservation SET expected_minor=1400")
    run("UPDATE period_reservation SET period_id='CAD', shop_id='other', currency='CAD'")

    add("meal", meal_id="meal", title="Tacos", dish_rules_json="{}")
    add("meal_template_revision", template_revision_id="v1", meal_id="meal", version_no=1,
        author_id="adult", title="Tacos", source_kind="manual", rules_json="{}", created_at=NOW)
    add("meal_slot", slot_id="dinner", shop_id="main", meal_id="meal", template_revision_id="v1",
        local_date=None, zone="UTC", kind="dinner", plate_commitments_json="{}")
    add("quantity", quantity_id="one", original_text="1 each", source_locale="en", numerator=1,
        denominator=1, unit="each")
    for seq, name in enumerate(["wrap", "egg"]):
        add("shop_line", line_id=name, shop_id="main", source_sequence=seq, original_text=name,
            source_locale="en", presentation_sequence=1-seq)
        add("need", need_id=name, shop_id="main", line_id=name, slot_id="dinner", quantity_id="one",
            purpose="meal", priority="required")
    for date in ("2026-11-03", None):
        run("UPDATE meal_slot SET local_date=? WHERE slot_id='dinner'", (date,))
        assert run("""SELECT n.need_id,s.slot_id,s.local_date FROM need n JOIN meal_slot s
                      USING(household_id,shop_id,slot_id) ORDER BY n.need_id""").fetchall() == [
                          ("egg", "dinner", date), ("wrap", "dinner", date)]
    assert run("SELECT line_id FROM shop_line ORDER BY source_sequence").fetchall() == [("wrap",), ("egg",)]
    assert run("SELECT line_id FROM shop_line ORDER BY presentation_sequence").fetchall() == [("egg",), ("wrap",)]
    reject(lambda: run("UPDATE shop_line SET source_sequence=20 WHERE line_id='wrap'"))
    for state in ("checked", "handled", "trash", "active"):
        run("UPDATE shop_line SET list_state=? WHERE line_id='wrap'", (state,))
        assert run("SELECT list_state,original_text,source_sequence FROM shop_line WHERE line_id='wrap'").fetchone() == (state, "wrap", 0)
    reject(lambda: run("UPDATE shop_line SET list_state='deleted'"))

    manual = dict(lot_id="stock", unit="each")
    for label in (None, "   "):
        reject(lambda: add("lot", **manual, food_label=label))
    add("lot", **manual, food_label="Tortillas")
    add("usable_observation", observation_id="count", lot_id="stock", usable_id="one", observed_at=NOW)
    allocation = dict(allocation_id="allocation", lot_id="stock", quantity_id="one", kind="reserved")
    reject(lambda: add("allocation", **allocation, need_id="wrap"))
    add("reviewed_lot_need_match", lot_id="stock", need_id="wrap", reviewer_id="adult", reviewed_at=NOW)
    reject(lambda: add("allocation", **allocation, need_id="egg"))
    add("allocation", **allocation, need_id="wrap")
    reject(lambda: run("UPDATE allocation SET need_id='egg'"))
    reject(lambda: run("DELETE FROM reviewed_lot_need_match"))

    for version in (1, 2):
        add("shop_revision", revision_id=f"v{version}", shop_id="main", display_no=version, author_id="adult",
            content_digest=f"h{version}", snapshot_json="{}", committed_at=NOW)
    line = dict(order_id="order", shop_id="main", line_id="wrap", confirmed_quantity_id="one")
    run("BEGIN IMMEDIATE")
    add("order_line", order_line_id="original", **line)
    reject(db.commit)
    db.rollback()
    assert run("SELECT COUNT(*) FROM order_line").fetchone() == (0,)
    run("BEGIN IMMEDIATE")
    add("order_line", order_line_id="original", **line)
    add("placed_order", order_id="order", shop_id="main", revision_id="v1", reporter_id="adult",
        evidence_source="shopper", reported_at=NOW)
    db.commit()
    reject(lambda: add("order_line", order_line_id="late", **{**line, "line_id": "egg"}))
    reject(lambda: run("UPDATE order_line SET line_id='egg'"))
    reject(lambda: run("DELETE FROM order_line"))
    reject(lambda: run("UPDATE placed_order SET revision_id='v2'"))
    reject(lambda: run("DELETE FROM placed_order"))
    add("amendment", amendment_id="change", shop_id="main", order_id="order", proposed_revision_id="v2",
        state="confirmed", retailer_confirmation_ref="evidence-2")
    assert run("SELECT order_line_id,line_id FROM order_line").fetchall() == [("original", "wrap")]
    assert run("SELECT revision_id FROM placed_order").fetchall() == [("v1",)]
    assert not run("PRAGMA foreign_key_check").fetchall()
    db.close()


if __name__ == "__main__":
    verify()
    print("Placement, unscheduled occurrences, list state/order, reviewed stock and currency checks passed.")
