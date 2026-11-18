CREATE TABLE ritc.staple_settings (
 household_id uuid NOT NULL, member_id uuid NOT NULL, grant_epoch integer NOT NULL,
 revision uuid NOT NULL, enabled boolean NOT NULL,
 PRIMARY KEY(household_id,member_id),
 FOREIGN KEY(household_id,member_id) REFERENCES ritc.member
);
CREATE TABLE ritc.staple_group (
 household_id uuid NOT NULL, member_id uuid NOT NULL, group_id uuid NOT NULL, name text NOT NULL CHECK (length(name) BETWEEN 1 AND 120),
 answer text CHECK (answer IN ('stillHave','dismiss','snooze')), answer_basis text, until_day date,
 CHECK ((answer IS NULL)=(answer_basis IS NULL) AND (answer IS NOT DISTINCT FROM 'snooze')=(until_day IS NOT NULL)),
 PRIMARY KEY(household_id,member_id,group_id),
 FOREIGN KEY(household_id,member_id) REFERENCES ritc.staple_settings ON DELETE CASCADE
);
CREATE TABLE ritc.staple_purchase (
 household_id uuid NOT NULL, member_id uuid NOT NULL, group_id uuid NOT NULL, lot_id uuid NOT NULL,
 shop_id uuid NOT NULL, arrival_id uuid NOT NULL, usable_id uuid NOT NULL, purchase_day date NOT NULL,
 PRIMARY KEY(household_id,member_id,lot_id),
 FOREIGN KEY(household_id,member_id,group_id) REFERENCES ritc.staple_group ON DELETE CASCADE,
 FOREIGN KEY(household_id,lot_id) REFERENCES ritc.pantry_lot ON DELETE CASCADE,
 FOREIGN KEY(household_id,shop_id,arrival_id) REFERENCES ritc.delivery_observation ON DELETE CASCADE,
 FOREIGN KEY(household_id,shop_id,usable_id) REFERENCES ritc.delivery_observation ON DELETE CASCADE
);
CREATE INDEX staple_purchase_group ON ritc.staple_purchase(household_id,member_id,group_id);
DO $$
DECLARE relation text;
BEGIN
 FOREACH relation IN ARRAY ARRAY['staple_settings','staple_group','staple_purchase'] LOOP
  EXECUTE format('ALTER TABLE ritc.%I ENABLE ROW LEVEL SECURITY',relation);
  EXECUTE format('ALTER TABLE ritc.%I FORCE ROW LEVEL SECURITY',relation);
  EXECUTE format('CREATE POLICY tenant_scope ON ritc.%I TO ritc_app USING(household_id::text=(SELECT current_setting(''app.household_id'',true))) WITH CHECK(household_id::text=(SELECT current_setting(''app.household_id'',true)))',relation);
  EXECUTE format('GRANT SELECT,INSERT,UPDATE,DELETE ON ritc.%I TO ritc_app',relation);
 END LOOP;
END $$;

-- Re-granting an adult starts fresh; removing membership also clears this person's preferences.
CREATE FUNCTION ritc.expire_staple_settings() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 DELETE FROM ritc.staple_settings WHERE household_id=NEW.household_id AND member_id=NEW.member_id;
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION ritc.expire_staple_settings() FROM PUBLIC;
CREATE TRIGGER expire_staple_settings AFTER UPDATE OF state,organizer,pantry_editor ON ritc.member FOR EACH ROW
 WHEN (NEW.pantry_grant_epoch<>OLD.pantry_grant_epoch) EXECUTE FUNCTION ritc.expire_staple_settings();

-- Forget the entire correspondence when physical evidence is removed. Losing one
-- of four purchases must not revive an older three-purchase interval or answer.
CREATE INDEX staple_purchase_lot ON ritc.staple_purchase(household_id,lot_id);
CREATE INDEX staple_purchase_arrival ON ritc.staple_purchase(household_id,shop_id,arrival_id);
CREATE INDEX staple_purchase_usable ON ritc.staple_purchase(household_id,shop_id,usable_id);
CREATE FUNCTION ritc.forget_staple_source() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF TG_TABLE_NAME='pantry_lot' THEN
   DELETE FROM ritc.staple_group g USING ritc.staple_purchase p
    WHERE (g.household_id,g.member_id,g.group_id)=(p.household_id,p.member_id,p.group_id)
      AND (p.household_id,p.lot_id)=(OLD.household_id,OLD.lot_id);
 ELSE
   DELETE FROM ritc.staple_group g USING ritc.staple_purchase p
    WHERE (g.household_id,g.member_id,g.group_id)=(p.household_id,p.member_id,p.group_id)
      AND (p.household_id,p.shop_id)=(OLD.household_id,OLD.shop_id)
      AND OLD.observation_id IN (p.arrival_id,p.usable_id);
 END IF;
 RETURN OLD;
END $$;
REVOKE ALL ON FUNCTION ritc.forget_staple_source() FROM PUBLIC;
CREATE TRIGGER forget_staple_lot BEFORE DELETE ON ritc.pantry_lot FOR EACH ROW EXECUTE FUNCTION ritc.forget_staple_source();
CREATE TRIGGER forget_staple_observation BEFORE DELETE ON ritc.delivery_observation FOR EACH ROW EXECUTE FUNCTION ritc.forget_staple_source();

ALTER FUNCTION ritc.privacy_erase_extension(uuid,uuid) RENAME TO privacy_erase_before_staples;
CREATE FUNCTION ritc.privacy_erase_extension(target_household uuid,target_member uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 DELETE FROM ritc.staple_settings WHERE household_id=target_household AND member_id=target_member;
 PERFORM ritc.privacy_erase_before_staples(target_household,target_member);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_extension(uuid,uuid) FROM PUBLIC;
