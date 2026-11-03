CREATE TABLE ritc.shared_meal_change (
 household_id uuid NOT NULL, shop_id uuid NOT NULL, proposal_id uuid NOT NULL,
 actor_id uuid NOT NULL, authority_epoch integer NOT NULL, grant_revision integer NOT NULL,
 shop_revision integer NOT NULL, occurrence_id uuid NOT NULL, base_meal_revision integer NOT NULL,
 body jsonb NOT NULL, original_meal jsonb NOT NULL, fingerprint text NOT NULL,
 state text NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','applied','dismissed')),
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(household_id,shop_id,proposal_id),
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,
 FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member
);
CREATE INDEX shared_meal_change_current ON ritc.shared_meal_change(household_id,shop_id,authority_epoch,grant_revision);
ALTER TABLE ritc.shared_meal_change ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.shared_meal_change FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON ritc.shared_meal_change
 USING(household_id::text=(SELECT current_setting('app.household_id',true)))
 WITH CHECK(household_id::text=(SELECT current_setting('app.household_id',true)));
GRANT SELECT,INSERT,UPDATE ON ritc.shared_meal_change TO ritc_app;
ALTER FUNCTION ritc.privacy_erase_extension(uuid,uuid) RENAME TO privacy_erase_family_decisions;
CREATE FUNCTION ritc.privacy_erase_extension(target_household uuid,target_member uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE affected record;
BEGIN
 -- Both original authors and accepted proposal authors may appear in later copies.
 FOR affected IN
   SELECT shop_id,occurrence_id FROM ritc.shared_meal_revision WHERE household_id=target_household AND actor_id=target_member
   UNION SELECT shop_id,occurrence_id FROM ritc.shared_meal_change WHERE household_id=target_household AND actor_id=target_member AND state='applied'
 LOOP
   DELETE FROM ritc.shared_meal_change WHERE household_id=target_household AND shop_id=affected.shop_id AND occurrence_id=affected.occurrence_id;
   DELETE FROM ritc.shared_meal_revision WHERE household_id=target_household AND shop_id=affected.shop_id AND occurrence_id=affected.occurrence_id;
 END LOOP;
 DELETE FROM ritc.shared_meal_change WHERE household_id=target_household AND actor_id=target_member;
 PERFORM ritc.privacy_erase_family_decisions(target_household,target_member);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_extension(uuid,uuid) FROM PUBLIC;
