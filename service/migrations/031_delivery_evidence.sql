-- The supply revision advances independently of the sealed checkout revision.
ALTER TABLE ritc.shop ADD COLUMN supply_revision integer NOT NULL DEFAULT 0 CHECK (supply_revision >= 0);

CREATE TABLE ritc.delivery_source (
 household_id uuid NOT NULL, shop_id uuid NOT NULL, source_id uuid NOT NULL,
 placed_revision integer NOT NULL, line_id uuid NOT NULL, segment_key uuid NOT NULL,
 food_name text NOT NULL, exclusion_tags text[] NOT NULL,
 actor_id uuid NOT NULL, operation_id uuid NOT NULL,
 PRIMARY KEY(household_id,shop_id,source_id),
 UNIQUE(household_id,shop_id,placed_revision,line_id,segment_key),
 FOREIGN KEY(household_id,shop_id,placed_revision) REFERENCES ritc.shop_snapshot,
 FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member,
 FOREIGN KEY(household_id,operation_id) REFERENCES ritc.operation DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX delivery_source_actor ON ritc.delivery_source(household_id,actor_id);

CREATE TABLE ritc.delivery_observation (
 household_id uuid NOT NULL, shop_id uuid NOT NULL, source_id uuid NOT NULL,
 observation_id uuid NOT NULL, kind text NOT NULL CHECK(kind IN ('arrival','usable')),
 supply_revision integer NOT NULL CHECK(supply_revision > 0), body jsonb NOT NULL,
 actor_id uuid NOT NULL, operation_id uuid NOT NULL, recorded_at timestamptz NOT NULL,
 PRIMARY KEY(household_id,shop_id,observation_id),
 UNIQUE(household_id,shop_id,supply_revision),
 FOREIGN KEY(household_id,shop_id,source_id) REFERENCES ritc.delivery_source ON DELETE CASCADE,
 FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member,
 FOREIGN KEY(household_id,operation_id) REFERENCES ritc.operation DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX delivery_head_lookup ON ritc.delivery_observation(household_id,shop_id,source_id,kind,supply_revision DESC);
CREATE INDEX delivery_observation_actor ON ritc.delivery_observation(household_id,actor_id);

ALTER TABLE ritc.delivery_source ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.delivery_source FORCE ROW LEVEL SECURITY;
ALTER TABLE ritc.delivery_observation ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.delivery_observation FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON ritc.delivery_source TO ritc_app
 USING(household_id::text=(SELECT current_setting('app.household_id',true)))
 WITH CHECK(household_id::text=(SELECT current_setting('app.household_id',true)));
CREATE POLICY tenant_scope ON ritc.delivery_observation TO ritc_app
 USING(household_id::text=(SELECT current_setting('app.household_id',true)))
 WITH CHECK(household_id::text=(SELECT current_setting('app.household_id',true)));
GRANT SELECT,INSERT ON ritc.delivery_source,ritc.delivery_observation TO ritc_app;

ALTER FUNCTION ritc.privacy_erase_extension(uuid,uuid) RENAME TO privacy_erase_before_delivery;
CREATE FUNCTION ritc.privacy_erase_extension(target_household uuid,target_member uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 -- Later corrections can repeat earlier wording or depend on an erased quantity.
 -- Remove the affected segment as a unit and invalidate reviews that used it.
 WITH removed AS (
   DELETE FROM ritc.delivery_source s WHERE s.household_id=target_household AND
     (s.actor_id=target_member OR EXISTS(SELECT 1 FROM ritc.delivery_observation o
       WHERE (o.household_id,o.shop_id,o.source_id)=(s.household_id,s.shop_id,s.source_id) AND o.actor_id=target_member)
      OR EXISTS(SELECT 1 FROM ritc.shop_snapshot ss, jsonb_array_elements(ss.snapshot->'lines') line
        WHERE (ss.household_id,ss.shop_id,ss.revision)=(s.household_id,s.shop_id,s.placed_revision)
          AND ss.digest=repeat('0',64) AND lower(line->>'lineId')=s.line_id::text AND line->>'originalItem'='Removed item'))
   RETURNING shop_id
 )
 UPDATE ritc.shop SET supply_revision=supply_revision+1 WHERE household_id=target_household AND shop_id IN (SELECT shop_id FROM removed);
 PERFORM ritc.privacy_erase_before_delivery(target_household,target_member);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_extension(uuid,uuid) FROM PUBLIC;
