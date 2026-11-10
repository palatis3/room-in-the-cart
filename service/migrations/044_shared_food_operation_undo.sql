-- Content-free effect lineage, recorded by the server at acceptance. No legacy
-- backfill: historical graph receipts alone cannot prove complete operation scope.
CREATE TABLE ritc.shared_food_operation_effect (
 household_id uuid NOT NULL,shop_id uuid NOT NULL,operation_id uuid NOT NULL,
 base_shop_revision integer NOT NULL CHECK(base_shop_revision>0),
 result_shop_revision integer NOT NULL CHECK(result_shop_revision=base_shop_revision+1),
 base_graph_revision integer NOT NULL CHECK(base_graph_revision>=0),
 result_graph_revision integer NOT NULL CHECK(result_graph_revision=base_graph_revision+1),
 classification text NOT NULL CHECK(classification IN ('eligible','first_adoption','meal_action','request_acceptance','store_action','missing_snapshot')),
 reverses_operation_id uuid,
 PRIMARY KEY(household_id,operation_id),UNIQUE(household_id,reverses_operation_id),
 CHECK(reverses_operation_id IS NULL OR reverses_operation_id<>operation_id),
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,
 FOREIGN KEY(household_id,operation_id) REFERENCES ritc.operation DEFERRABLE INITIALLY DEFERRED,
 FOREIGN KEY(household_id,reverses_operation_id) REFERENCES ritc.operation,
 FOREIGN KEY(household_id,shop_id,result_graph_revision) REFERENCES ritc.shared_demand_revision DEFERRABLE INITIALLY DEFERRED
);
ALTER TABLE ritc.shared_food_operation_effect ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.shared_food_operation_effect FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON ritc.shared_food_operation_effect TO ritc_app
 USING(household_id::text=(SELECT current_setting('app.household_id',true)))
 WITH CHECK(household_id::text=(SELECT current_setting('app.household_id',true)));
GRANT SELECT,INSERT ON ritc.shared_food_operation_effect TO ritc_app;
CREATE TRIGGER shared_food_effect_immutable BEFORE UPDATE OR DELETE ON ritc.shared_food_operation_effect
 FOR EACH ROW EXECUTE FUNCTION ritc.immutable_row();
-- No copied food/meal/request wording or command body is stored. Eligibility and
-- replay always require unredacted operation/snapshot/graph lineage. Existing
-- worker erasure invalidates those copies/digests, receipts and operation responses.
