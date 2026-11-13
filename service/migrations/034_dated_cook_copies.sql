-- A non-content counter per shop occurrence survives erasure of individual copies.
-- Versions span meal revisions and languages without mutating sealed meal facts.
CREATE TABLE ritc.cook_copy_series (
 household_id uuid NOT NULL, shop_id uuid NOT NULL, occurrence_id uuid NOT NULL, last_version integer NOT NULL CHECK(last_version>0),
 PRIMARY KEY(household_id,shop_id,occurrence_id),
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop
);

CREATE TABLE ritc.dated_cook_copy (
 household_id uuid NOT NULL, shop_id uuid NOT NULL, copy_id uuid NOT NULL,
 occurrence_id uuid NOT NULL, meal_revision integer NOT NULL, version integer NOT NULL CHECK(version>0),
 shop_revision integer NOT NULL, placed_revision integer NOT NULL, authority_epoch integer NOT NULL,
 supply_revision integer NOT NULL CHECK(supply_revision>=0), language text NOT NULL CHECK(language IN ('en','es')),
 reviewed_text text NOT NULL CHECK(length(reviewed_text) BETWEEN 1 AND 16000),
 actor_id uuid NOT NULL, created_at timestamptz NOT NULL,
 PRIMARY KEY(household_id,copy_id), UNIQUE(household_id,shop_id,occurrence_id,version),
 FOREIGN KEY(household_id,shop_id,occurrence_id) REFERENCES ritc.cook_copy_series,
 FOREIGN KEY(household_id,copy_id) REFERENCES ritc.operation DEFERRABLE INITIALLY DEFERRED,
 FOREIGN KEY(household_id,shop_id,occurrence_id,meal_revision) REFERENCES ritc.shared_meal_revision ON DELETE CASCADE,
 FOREIGN KEY(household_id,shop_id,placed_revision) REFERENCES ritc.shop_snapshot,
 FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member
);
CREATE INDEX dated_cook_copy_actor ON ritc.dated_cook_copy(household_id,actor_id);
CREATE TABLE ritc.cook_copy_send (
 household_id uuid NOT NULL, send_id uuid NOT NULL, copy_id uuid NOT NULL, recipient text NOT NULL CHECK(length(recipient) BETWEEN 1 AND 80),
 actor_id uuid NOT NULL, sent_at timestamptz NOT NULL,
 PRIMARY KEY(household_id,send_id),
 FOREIGN KEY(household_id,copy_id) REFERENCES ritc.dated_cook_copy ON DELETE CASCADE,
 FOREIGN KEY(household_id,send_id) REFERENCES ritc.operation DEFERRABLE INITIALLY DEFERRED,
 FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member
);
CREATE INDEX cook_copy_send_copy ON ritc.cook_copy_send(household_id,copy_id);
CREATE INDEX cook_copy_send_actor ON ritc.cook_copy_send(household_id,actor_id);

-- Keep a pointer instead of rediscovering a prior send after erasure.
CREATE TABLE ritc.cook_copy_baseline (
 household_id uuid NOT NULL, shop_id uuid NOT NULL, occurrence_id uuid NOT NULL, recipient text NOT NULL,
 send_id uuid NOT NULL, PRIMARY KEY(household_id,shop_id,occurrence_id,recipient),
 FOREIGN KEY(household_id,send_id) REFERENCES ritc.cook_copy_send ON DELETE CASCADE
);
CREATE INDEX cook_copy_baseline_send ON ritc.cook_copy_baseline(household_id,send_id);

DO $$
DECLARE relation text;
BEGIN
 FOREACH relation IN ARRAY ARRAY['cook_copy_series','dated_cook_copy','cook_copy_send','cook_copy_baseline'] LOOP
  EXECUTE format('ALTER TABLE ritc.%I ENABLE ROW LEVEL SECURITY',relation);
  EXECUTE format('ALTER TABLE ritc.%I FORCE ROW LEVEL SECURITY',relation);
  EXECUTE format('CREATE POLICY tenant_scope ON ritc.%I TO ritc_app USING(household_id::text=(SELECT current_setting(''app.household_id'',true))) WITH CHECK(household_id::text=(SELECT current_setting(''app.household_id'',true)))',relation);
 END LOOP;
END $$;
GRANT SELECT,INSERT ON ritc.cook_copy_series,ritc.dated_cook_copy,ritc.cook_copy_send,ritc.cook_copy_baseline TO ritc_app;
GRANT UPDATE(last_version) ON ritc.cook_copy_series TO ritc_app;
GRANT UPDATE(send_id) ON ritc.cook_copy_baseline TO ritc_app;

-- A snapshot's contents change only during authorized source erasure. Remove
-- its derived text at the actual redaction, including copies by later shoppers.
-- New text reviewed against an already-redacted snapshot can still be kept.
CREATE FUNCTION ritc.erase_redacted_cook_copies() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 DELETE FROM ritc.dated_cook_copy WHERE household_id=NEW.household_id AND shop_id=NEW.shop_id AND placed_revision=NEW.revision;
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION ritc.erase_redacted_cook_copies() FROM PUBLIC;
CREATE TRIGGER erase_redacted_cook_copies AFTER UPDATE OF snapshot ON ritc.shop_snapshot
 FOR EACH ROW WHEN (OLD.snapshot IS DISTINCT FROM NEW.snapshot) EXECUTE FUNCTION ritc.erase_redacted_cook_copies();

ALTER FUNCTION ritc.privacy_erase_extension(uuid,uuid) RENAME TO privacy_erase_before_dated_cook_copies;
CREATE FUNCTION ritc.privacy_erase_extension(target_household uuid,target_member uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 -- Edited wording may carry earlier wording and reviewed delivery facts. Erase
 -- the affected version and later edits, including those by another shopper.
 DELETE FROM ritc.dated_cook_copy c WHERE c.household_id=target_household AND (
   EXISTS (SELECT 1 FROM ritc.dated_cook_copy a WHERE (a.household_id,a.shop_id,a.occurrence_id)=(c.household_id,c.shop_id,c.occurrence_id) AND a.actor_id=target_member AND a.version<=c.version)
   OR EXISTS (SELECT 1 FROM ritc.delivery_source s JOIN ritc.operation o USING(household_id,operation_id)
              WHERE (s.household_id,s.shop_id)=(c.household_id,c.shop_id) AND s.actor_id=target_member AND o.committed_at<=c.created_at)
   OR EXISTS (SELECT 1 FROM ritc.delivery_observation d WHERE (d.household_id,d.shop_id)=(c.household_id,c.shop_id)
              AND d.actor_id=target_member AND d.supply_revision<=c.supply_revision)
   OR EXISTS (SELECT 1 FROM ritc.delivery_ingredient_review d WHERE (d.household_id,d.shop_id)=(c.household_id,c.shop_id)
              AND d.actor_id=target_member AND d.supply_revision<=c.supply_revision)
   OR EXISTS (SELECT 1 FROM ritc.delivery_reservation d WHERE (d.household_id,d.shop_id)=(c.household_id,c.shop_id)
              AND d.actor_id=target_member AND d.supply_revision<=c.supply_revision)
 );
 DELETE FROM ritc.cook_copy_send WHERE household_id=target_household AND actor_id=target_member;
 -- Erasure of a sealed meal (including accepted family proposals) cascades to
 -- its copies, sends and current baselines.
 PERFORM ritc.privacy_erase_before_dated_cook_copies(target_household,target_member);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_extension(uuid,uuid) FROM PUBLIC;
