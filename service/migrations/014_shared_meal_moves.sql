CREATE TABLE ritc.meal_planner (
 household_id uuid NOT NULL, shop_id uuid NOT NULL, authority_epoch integer NOT NULL,
 revision integer NOT NULL, planner_id uuid, PRIMARY KEY(household_id,shop_id),
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,
 FOREIGN KEY(household_id,planner_id) REFERENCES ritc.member
);
CREATE TABLE ritc.meal_move (
 household_id uuid NOT NULL, shop_id uuid NOT NULL, proposal_id uuid NOT NULL,
 actor_id uuid NOT NULL, authority_epoch integer NOT NULL, grant_revision integer NOT NULL,
 shop_revision integer NOT NULL, occurrence_id uuid NOT NULL, proposed_day date NOT NULL,
 state text NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','applied','dismissed')),
 PRIMARY KEY(household_id,shop_id,proposal_id),
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,
 FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member
);
CREATE INDEX meal_move_current ON ritc.meal_move(household_id,shop_id,shop_revision,state);
DO $$ DECLARE t text; BEGIN FOREACH t IN ARRAY ARRAY['meal_planner','meal_move'] LOOP
 EXECUTE format('ALTER TABLE ritc.%I ENABLE ROW LEVEL SECURITY',t);
 EXECUTE format('ALTER TABLE ritc.%I FORCE ROW LEVEL SECURITY',t);
 EXECUTE format('CREATE POLICY tenant_scope ON ritc.%I USING(household_id::text=(SELECT current_setting(''app.household_id'',true))) WITH CHECK(household_id::text=(SELECT current_setting(''app.household_id'',true)))',t);
 EXECUTE format('GRANT SELECT,INSERT,UPDATE ON ritc.%I TO ritc_app',t);
END LOOP; END $$;
ALTER FUNCTION ritc.privacy_erase_extension(uuid,uuid) RENAME TO privacy_erase_shared_meals;
CREATE FUNCTION ritc.privacy_erase_extension(target_household uuid,target_member uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 DELETE FROM ritc.meal_move WHERE household_id=target_household AND actor_id=target_member;
 UPDATE ritc.meal_planner SET planner_id=NULL,revision=revision+1 WHERE household_id=target_household AND planner_id=target_member;
 PERFORM ritc.privacy_erase_shared_meals(target_household,target_member);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_extension(uuid,uuid) FROM PUBLIC;
