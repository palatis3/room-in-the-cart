-- A household disclosure is reviewed independently of any shop, grant-bound idea or private cookbook.
CREATE TABLE ritc.tonight_recipe (
 household_id uuid NOT NULL REFERENCES ritc.household, recipe_id uuid NOT NULL, actor_id uuid NOT NULL,
 revision integer NOT NULL CHECK(revision>0), recipe jsonb, client_key uuid NOT NULL, device_id uuid NOT NULL,
 fingerprint text, PRIMARY KEY(household_id,recipe_id),
 FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member,
 FOREIGN KEY(household_id,device_id) REFERENCES ritc.device,
 CHECK ((recipe IS NULL)=(fingerprint IS NULL)),
 CHECK (recipe IS NULL OR (jsonb_typeof(recipe)='object' AND octet_length(recipe::text)<=65536))
);
CREATE UNIQUE INDEX tonight_recipe_write ON ritc.tonight_recipe(household_id,actor_id,client_key);
CREATE TABLE ritc.tonight_choice (
 household_id uuid NOT NULL, shop_id uuid NOT NULL, occurrence_id uuid NOT NULL, operation_id uuid NOT NULL,
 recipe_id uuid NOT NULL, recipe_revision integer NOT NULL, grant_epoch integer NOT NULL,
 PRIMARY KEY(household_id,shop_id,occurrence_id), UNIQUE(household_id,operation_id),
 FOREIGN KEY(household_id,recipe_id) REFERENCES ritc.tonight_recipe,
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,
 FOREIGN KEY(household_id,operation_id) REFERENCES ritc.operation ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);
DO $$ DECLARE tab text; BEGIN
 FOREACH tab IN ARRAY ARRAY['tonight_recipe','tonight_choice'] LOOP
  EXECUTE format('ALTER TABLE ritc.%I ENABLE ROW LEVEL SECURITY',tab);
  EXECUTE format('ALTER TABLE ritc.%I FORCE ROW LEVEL SECURITY',tab);
  EXECUTE format('CREATE POLICY tenant_scope ON ritc.%I TO ritc_app USING(household_id::text=(SELECT current_setting(''app.household_id'',true))) WITH CHECK(household_id::text=(SELECT current_setting(''app.household_id'',true)))',tab);
  EXECUTE format('GRANT SELECT,INSERT ON ritc.%I TO ritc_app',tab);
 END LOOP;
END $$;
GRANT UPDATE(revision,recipe,client_key,device_id,fingerprint) ON ritc.tonight_recipe TO ritc_app;
-- Reuse source authorship in downstream archives, cook copies and demand provenance.
CREATE VIEW ritc.tonight_meal_author WITH (security_invoker=true) AS
 SELECT c.household_id,c.shop_id,c.occurrence_id,r.actor_id
 FROM ritc.tonight_choice c JOIN ritc.tonight_recipe r USING(household_id,recipe_id);
GRANT SELECT ON ritc.tonight_meal_author TO ritc_app;
ALTER FUNCTION ritc.privacy_erase_extension(uuid,uuid) RENAME TO privacy_erase_before_tonight;
CREATE FUNCTION ritc.privacy_erase_extension(h uuid,m uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE chosen record;
BEGIN
 IF EXISTS(SELECT FROM ritc.tonight_recipe WHERE household_id=h AND actor_id=m AND recipe IS NOT NULL)
   AND NOT ritc.privacy_erasure_authorized() THEN RAISE EXCEPTION 'erasure authority required'; END IF;
 FOR chosen IN SELECT c.* FROM ritc.tonight_choice c JOIN ritc.tonight_recipe r USING(household_id,recipe_id)
   WHERE c.household_id=h AND r.actor_id=m LOOP
  DELETE FROM ritc.operation_response WHERE household_id=h AND operation_id=chosen.operation_id;
  DELETE FROM ritc.shared_meal_change WHERE household_id=h AND shop_id=chosen.shop_id AND occurrence_id=chosen.occurrence_id;
  DELETE FROM ritc.dated_cook_copy WHERE household_id=h AND shop_id=chosen.shop_id AND occurrence_id=chosen.occurrence_id;
  DELETE FROM ritc.shared_meal_revision WHERE household_id=h AND shop_id=chosen.shop_id AND occurrence_id=chosen.occurrence_id;
 END LOOP;
 UPDATE ritc.tonight_recipe SET recipe=NULL,fingerprint=NULL WHERE household_id=h AND actor_id=m;
 PERFORM ritc.privacy_erase_before_tonight(h,m);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_extension(uuid,uuid) FROM PUBLIC;
