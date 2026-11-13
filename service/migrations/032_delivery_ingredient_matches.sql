-- Explicit shopper decisions, scoped to one physical segment and sealed meal revision.
CREATE TABLE ritc.delivery_ingredient_review (
 household_id uuid NOT NULL, shop_id uuid NOT NULL, source_id uuid NOT NULL,
 occurrence_id uuid NOT NULL, meal_revision integer NOT NULL, ingredient_id uuid NOT NULL,
 supply_revision integer NOT NULL CHECK(supply_revision > 0), matched boolean NOT NULL,
 actor_id uuid NOT NULL, operation_id uuid NOT NULL,
 PRIMARY KEY(household_id,shop_id,supply_revision),
 FOREIGN KEY(household_id,shop_id,source_id) REFERENCES ritc.delivery_source ON DELETE CASCADE,
 FOREIGN KEY(household_id,shop_id,occurrence_id,meal_revision) REFERENCES ritc.shared_meal_revision ON DELETE CASCADE,
 FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member,
 FOREIGN KEY(household_id,operation_id) REFERENCES ritc.operation DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX delivery_ingredient_head ON ritc.delivery_ingredient_review
 (household_id,shop_id,source_id,occurrence_id,meal_revision,ingredient_id,supply_revision DESC);
CREATE UNIQUE INDEX delivery_ingredient_operation ON ritc.delivery_ingredient_review(household_id,operation_id);
CREATE INDEX delivery_ingredient_actor ON ritc.delivery_ingredient_review(household_id,actor_id);
ALTER TABLE ritc.delivery_ingredient_review ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.delivery_ingredient_review FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON ritc.delivery_ingredient_review TO ritc_app
 USING(household_id::text=(SELECT current_setting('app.household_id',true)))
 WITH CHECK(household_id::text=(SELECT current_setting('app.household_id',true)));
GRANT SELECT,INSERT ON ritc.delivery_ingredient_review TO ritc_app;

ALTER FUNCTION ritc.privacy_erase_extension(uuid,uuid) RENAME TO privacy_erase_before_ingredient_reviews;
CREATE FUNCTION ritc.privacy_erase_extension(target_household uuid,target_member uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 -- Invalidate readers if the meal inventory changes, including an erased planner's
 -- accepted contribution that was copied to a new revision by a different shopper.
 UPDATE ritc.shop s SET supply_revision=supply_revision+1
 WHERE s.household_id=target_household AND s.placed_revision IS NOT NULL AND (
   EXISTS(SELECT 1 FROM ritc.shared_meal_revision m WHERE m.household_id=s.household_id AND m.shop_id=s.shop_id AND m.actor_id=target_member)
   OR EXISTS(SELECT 1 FROM ritc.shared_meal_change c WHERE c.household_id=s.household_id AND c.shop_id=s.shop_id AND c.actor_id=target_member AND c.state='applied')
   OR EXISTS(SELECT 1 FROM ritc.delivery_ingredient_review r WHERE r.household_id=s.household_id AND r.shop_id=s.shop_id AND r.actor_id=target_member)
 );
 DELETE FROM ritc.delivery_ingredient_review r USING ritc.delivery_ingredient_review erased
 WHERE erased.household_id=target_household AND erased.actor_id=target_member
 AND (r.household_id,r.shop_id,r.source_id,r.occurrence_id,r.meal_revision,r.ingredient_id)=
     (erased.household_id,erased.shop_id,erased.source_id,erased.occurrence_id,erased.meal_revision,erased.ingredient_id);
 PERFORM ritc.privacy_erase_before_ingredient_reviews(target_household,target_member);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_extension(uuid,uuid) FROM PUBLIC;
