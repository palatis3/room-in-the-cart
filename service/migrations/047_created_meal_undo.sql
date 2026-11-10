-- Proposed migration 047. Root installation/PG qualification required.
-- 046 belongs to tracking. This does not modify migration 045 or backfill Undo authority.
CREATE TABLE ritc.shared_meal_occurrence_identity (
 household_id uuid NOT NULL,shop_id uuid NOT NULL,occurrence_id uuid NOT NULL,
 first_operation_id uuid,first_shop_revision integer NOT NULL CHECK(first_shop_revision>0),
 PRIMARY KEY(household_id,shop_id,occurrence_id),
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,
 FOREIGN KEY(household_id,first_operation_id) REFERENCES ritc.operation DEFERRABLE INITIALLY DEFERRED
);
-- Every normal creation has always saved mealRefs in the same transaction.
-- Invalidated snapshot digests cannot authorize restoration but their used IDs
-- still reject an attempted new first-use certificate. No private text is copied.
INSERT INTO ritc.shared_meal_occurrence_identity(household_id,shop_id,occurrence_id,first_operation_id,first_shop_revision)
 SELECT household_id,shop_id,occurrence_id,NULL,min(revision) FROM (
  SELECT household_id,shop_id,occurrence_id,revision FROM ritc.shared_meal_revision
  UNION ALL
  SELECT s.household_id,s.shop_id,(r->>'occurrenceId')::uuid,(r->>'revision')::integer
   FROM ritc.shop_snapshot s,jsonb_array_elements(COALESCE(s.snapshot->'mealRefs','[]')) r
 ) seen GROUP BY household_id,shop_id,occurrence_id;
ALTER TABLE ritc.shared_meal_occurrence_identity ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.shared_meal_occurrence_identity FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON ritc.shared_meal_occurrence_identity TO ritc_app
 USING(household_id::text=(SELECT current_setting('app.household_id',true)))
 WITH CHECK(household_id::text=(SELECT current_setting('app.household_id',true)));
GRANT SELECT,INSERT ON ritc.shared_meal_occurrence_identity TO ritc_app;
CREATE TRIGGER shared_meal_occurrence_identity_immutable BEFORE UPDATE OR DELETE ON ritc.shared_meal_occurrence_identity
 FOR EACH ROW EXECUTE FUNCTION ritc.immutable_row();
-- Register even ordinary/untracked/recreated meal writes. Conflicts preserve
-- the original used identity and never turn a historical ID into new authority.
CREATE FUNCTION ritc.remember_shared_meal_occurrence() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 INSERT INTO ritc.shared_meal_occurrence_identity(household_id,shop_id,occurrence_id,first_operation_id,first_shop_revision)
 VALUES(NEW.household_id,NEW.shop_id,NEW.occurrence_id,NULL,NEW.revision)
 ON CONFLICT(household_id,shop_id,occurrence_id) DO NOTHING;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ritc.remember_shared_meal_occurrence() FROM PUBLIC;
CREATE TRIGGER remember_shared_meal_occurrence BEFORE INSERT ON ritc.shared_meal_revision
 FOR EACH ROW EXECUTE FUNCTION ritc.remember_shared_meal_occurrence();
CREATE TABLE ritc.shared_food_meal_creation_effect (
 household_id uuid NOT NULL,shop_id uuid NOT NULL,operation_id uuid NOT NULL,occurrence_id uuid NOT NULL,
 base_shop_revision integer NOT NULL CHECK(base_shop_revision>0),
 result_meal_revision integer NOT NULL CHECK(result_meal_revision=base_shop_revision+1),
 absence_digest text NOT NULL CHECK(absence_digest ~ '^[a-f0-9]{64}$'),
 result_meal_digest text NOT NULL CHECK(result_meal_digest ~ '^[a-f0-9]{64}$'),
 PRIMARY KEY(household_id,operation_id),
 FOREIGN KEY(household_id,shop_id,occurrence_id) REFERENCES ritc.shared_meal_occurrence_identity,
 FOREIGN KEY(household_id,operation_id) REFERENCES ritc.shared_food_operation_effect
);
ALTER TABLE ritc.shared_food_meal_creation_effect ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.shared_food_meal_creation_effect FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON ritc.shared_food_meal_creation_effect TO ritc_app
 USING(household_id::text=(SELECT current_setting('app.household_id',true)))
 WITH CHECK(household_id::text=(SELECT current_setting('app.household_id',true)));
GRANT SELECT,INSERT ON ritc.shared_food_meal_creation_effect TO ritc_app;
CREATE TRIGGER shared_food_meal_creation_effect_immutable BEFORE UPDATE OR DELETE ON ritc.shared_food_meal_creation_effect
 FOR EACH ROW EXECUTE FUNCTION ritc.immutable_row();
-- No FK to historical meal rows. Existing privacy erasure deletes those bytes;
-- read/replay then fail closed. Identity and proof contain no meal/source copy.
