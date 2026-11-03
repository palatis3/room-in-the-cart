-- Preserve the meal facts that accompanied each reviewed basket revision.
CREATE TABLE ritc.shared_meal_revision (
 household_id uuid NOT NULL, shop_id uuid NOT NULL, occurrence_id uuid NOT NULL,
 revision integer NOT NULL CHECK (revision > 0), actor_id uuid NOT NULL, meal jsonb,
 PRIMARY KEY (household_id, shop_id, occurrence_id, revision),
 FOREIGN KEY (household_id, shop_id) REFERENCES ritc.shop,
 FOREIGN KEY (household_id, actor_id) REFERENCES ritc.member
);
CREATE INDEX shared_meal_author ON ritc.shared_meal_revision(household_id,actor_id);
ALTER TABLE ritc.shared_meal_revision ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.shared_meal_revision FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON ritc.shared_meal_revision
 USING(household_id::text=(SELECT current_setting('app.household_id',true)))
 WITH CHECK(household_id::text=(SELECT current_setting('app.household_id',true)));
GRANT SELECT, INSERT ON ritc.shared_meal_revision TO ritc_app;

ALTER FUNCTION ritc.privacy_erase_extension(uuid,uuid) RENAME TO privacy_erase_history;
CREATE FUNCTION ritc.privacy_erase_extension(target_household uuid,target_member uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 PERFORM ritc.privacy_erase_history(target_household,target_member);
 -- Later edits can carry the original author's labels. Erase all copies of that occurrence.
 DELETE FROM ritc.shared_meal_revision m WHERE m.household_id=target_household
 AND EXISTS (SELECT 1 FROM ritc.shared_meal_revision a WHERE a.household_id=m.household_id
 AND a.shop_id=m.shop_id AND a.occurrence_id=m.occurrence_id AND a.actor_id=target_member);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_extension(uuid,uuid) FROM PUBLIC;
