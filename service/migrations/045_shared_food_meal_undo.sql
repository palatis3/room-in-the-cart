-- Content-free acceptance-time meal lineage. No legacy backfill and no meal copy.
-- Revisions alone do not bind the accepted removal tombstone, original proposal,
-- or historical meal bytes; these digests fail closed after erasure or drift.
CREATE TABLE ritc.shared_food_meal_effect (
 household_id uuid NOT NULL,shop_id uuid NOT NULL,operation_id uuid NOT NULL,
 occurrence_id uuid NOT NULL,before_meal_revision integer NOT NULL CHECK(before_meal_revision>0),
 result_meal_revision integer NOT NULL CHECK(result_meal_revision>before_meal_revision),
 before_meal_digest text NOT NULL CHECK(before_meal_digest ~ '^[a-f0-9]{64}$'),
 result_meal_digest text NOT NULL CHECK(result_meal_digest ~ '^[a-f0-9]{64}$'),
 proposal_kind text CHECK(proposal_kind IN ('change','move')),proposal_id uuid,proposal_digest text,
 CHECK((proposal_kind IS NULL AND proposal_id IS NULL AND proposal_digest IS NULL)
    OR (proposal_kind IS NOT NULL AND proposal_id IS NOT NULL AND proposal_digest IS NOT NULL AND proposal_digest ~ '^[a-f0-9]{64}$')),
 PRIMARY KEY(household_id,operation_id),
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,
 FOREIGN KEY(household_id,operation_id) REFERENCES ritc.shared_food_operation_effect
);
ALTER TABLE ritc.shared_food_meal_effect ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.shared_food_meal_effect FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON ritc.shared_food_meal_effect TO ritc_app
 USING(household_id::text=(SELECT current_setting('app.household_id',true)))
 WITH CHECK(household_id::text=(SELECT current_setting('app.household_id',true)));
GRANT SELECT,INSERT ON ritc.shared_food_meal_effect TO ritc_app;
CREATE TRIGGER shared_food_meal_effect_immutable BEFORE UPDATE OR DELETE ON ritc.shared_food_meal_effect
 FOR EACH ROW EXECUTE FUNCTION ritc.immutable_row();
-- No FK to historical meal/proposal rows: existing authorized erasure deletes
-- those facts. Surviving content-free references cannot authorize replay.
