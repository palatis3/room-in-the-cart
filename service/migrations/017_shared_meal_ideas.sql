CREATE TABLE ritc.shared_meal_idea (
 household_id uuid NOT NULL, shop_id uuid NOT NULL, idea_id uuid NOT NULL, actor_id uuid NOT NULL,
 authority_epoch integer NOT NULL, grant_revision integer NOT NULL, revision integer NOT NULL CHECK(revision>0),
 state text NOT NULL CHECK(state IN ('draft','approved')), draft jsonb NOT NULL, updated_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(household_id,shop_id,idea_id),
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,
 FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member
);
CREATE TABLE ritc.shared_idea_receipt (
 household_id uuid NOT NULL, shop_id uuid NOT NULL, idea_id uuid NOT NULL, actor_id uuid NOT NULL,
 client_key uuid NOT NULL, fingerprint text NOT NULL, response jsonb NOT NULL,
 PRIMARY KEY(household_id,actor_id,client_key),
 FOREIGN KEY(household_id,shop_id,idea_id) REFERENCES ritc.shared_meal_idea ON DELETE CASCADE
);
DO $$ DECLARE t text; BEGIN FOREACH t IN ARRAY ARRAY['shared_meal_idea','shared_idea_receipt'] LOOP
 EXECUTE format('ALTER TABLE ritc.%I ENABLE ROW LEVEL SECURITY',t);
 EXECUTE format('ALTER TABLE ritc.%I FORCE ROW LEVEL SECURITY',t);
 EXECUTE format('CREATE POLICY tenant_scope ON ritc.%I USING(household_id::text=(SELECT current_setting(''app.household_id'',true))) WITH CHECK(household_id::text=(SELECT current_setting(''app.household_id'',true)))',t);
 EXECUTE format('GRANT SELECT,INSERT ON ritc.%I TO ritc_app',t);
END LOOP; END $$;
GRANT UPDATE ON ritc.shared_meal_idea TO ritc_app;
ALTER FUNCTION ritc.privacy_erase_extension(uuid,uuid) RENAME TO privacy_erase_shared_changes;
CREATE FUNCTION ritc.privacy_erase_extension(target_household uuid,target_member uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 DELETE FROM ritc.shared_meal_idea WHERE household_id=target_household AND actor_id=target_member;
 PERFORM ritc.privacy_erase_shared_changes(target_household,target_member);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_extension(uuid,uuid) FROM PUBLIC;
ALTER TABLE ritc.shared_meal_change ALTER COLUMN base_meal_revision DROP NOT NULL;
ALTER TABLE ritc.shared_meal_change ALTER COLUMN original_meal DROP NOT NULL;
ALTER TABLE ritc.shared_meal_change ADD CONSTRAINT explicit_new_meal_source CHECK(
 (base_meal_revision IS NOT NULL AND original_meal IS NOT NULL)
 OR (base_meal_revision IS NULL AND original_meal IS NULL AND body ? 'approvedIdeaId' AND body ? 'approvedIdeaRevision'));
