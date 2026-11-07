CREATE TABLE ritc.delivery_reservation (
 household_id uuid NOT NULL, shop_id uuid NOT NULL, source_id uuid NOT NULL,
 occurrence_id uuid NOT NULL, meal_revision integer NOT NULL, ingredient_id uuid NOT NULL, group_id uuid NOT NULL,
 operation_id uuid NOT NULL, predecessor_id uuid, match_operation_id uuid NOT NULL,
 supply_revision integer NOT NULL CHECK(supply_revision>0), quantity jsonb,
 actor_id uuid NOT NULL, recorded_at timestamptz NOT NULL,
 PRIMARY KEY(household_id,operation_id), UNIQUE(household_id,shop_id,supply_revision),
 FOREIGN KEY(household_id,operation_id) REFERENCES ritc.operation DEFERRABLE INITIALLY DEFERRED,
 FOREIGN KEY(household_id,match_operation_id) REFERENCES ritc.delivery_ingredient_review(household_id,operation_id) ON DELETE CASCADE,
 FOREIGN KEY(household_id,shop_id,source_id) REFERENCES ritc.delivery_source ON DELETE CASCADE,
 FOREIGN KEY(household_id,shop_id,occurrence_id,meal_revision) REFERENCES ritc.shared_meal_revision ON DELETE CASCADE,
 FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member
);
CREATE INDEX delivery_reservation_head ON ritc.delivery_reservation
 (household_id,shop_id,source_id,occurrence_id,meal_revision,ingredient_id,group_id,supply_revision DESC);
CREATE INDEX delivery_reservation_actor ON ritc.delivery_reservation(household_id,actor_id);
CREATE INDEX delivery_reservation_match ON ritc.delivery_reservation(household_id,match_operation_id);
ALTER TABLE ritc.delivery_reservation ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.delivery_reservation FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON ritc.delivery_reservation TO ritc_app
 USING(household_id::text=(SELECT current_setting('app.household_id',true)))
 WITH CHECK(household_id::text=(SELECT current_setting('app.household_id',true)));
GRANT SELECT,INSERT ON ritc.delivery_reservation TO ritc_app;

ALTER FUNCTION ritc.privacy_erase_extension(uuid,uuid) RENAME TO privacy_erase_before_delivery_reservations;
CREATE FUNCTION ritc.privacy_erase_extension(target_household uuid,target_member uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 -- Remove the entire affected decision history so erasing a correction or release
 -- cannot revive an earlier reservation by a different shopper.
 WITH removed AS (
   DELETE FROM ritc.delivery_reservation r USING ritc.delivery_reservation erased
   WHERE erased.household_id=target_household AND erased.actor_id=target_member
   AND (r.household_id,r.shop_id,r.source_id,r.occurrence_id,r.meal_revision,r.ingredient_id,r.group_id)=
       (erased.household_id,erased.shop_id,erased.source_id,erased.occurrence_id,erased.meal_revision,erased.ingredient_id,erased.group_id)
   RETURNING r.shop_id
 )
 UPDATE ritc.shop SET supply_revision=supply_revision+1 WHERE household_id=target_household AND shop_id IN (SELECT shop_id FROM removed);
 PERFORM ritc.privacy_erase_before_delivery_reservations(target_household,target_member);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_extension(uuid,uuid) FROM PUBLIC;
