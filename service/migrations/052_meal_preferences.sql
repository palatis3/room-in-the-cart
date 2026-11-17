-- The dedicated read grant never authorizes writes, and pantry grants never
-- authorize preference reads. Profile revisions survive erasure without content.
ALTER TABLE ritc.member
 ADD COLUMN preference_reader boolean NOT NULL DEFAULT false,
 ADD COLUMN preference_grant_epoch integer NOT NULL DEFAULT 0 CHECK(preference_grant_epoch >= 0),
 ADD CHECK(NOT preference_reader OR (kind='adult' AND state='active' AND NOT organizer));
GRANT UPDATE(preference_reader) ON ritc.member TO ritc_app;

CREATE FUNCTION ritc.advance_preference_grant() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF NEW.state<>'active' OR NEW.kind<>'adult' OR NEW.organizer IS DISTINCT FROM OLD.organizer THEN
  NEW.preference_reader:=false;
 END IF;
 IF (OLD.kind,OLD.state,OLD.organizer,OLD.preference_reader) IS DISTINCT FROM
    (NEW.kind,NEW.state,NEW.organizer,NEW.preference_reader) THEN
  NEW.preference_grant_epoch:=OLD.preference_grant_epoch+1;
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ritc.advance_preference_grant() FROM PUBLIC;
CREATE TRIGGER advance_preference_grant BEFORE UPDATE ON ritc.member
 FOR EACH ROW EXECUTE FUNCTION ritc.advance_preference_grant();

CREATE TABLE ritc.meal_preference_profile (
 household_id uuid PRIMARY KEY REFERENCES ritc.household,
 revision uuid NOT NULL,
 settings jsonb CHECK(settings IS NULL OR (jsonb_typeof(settings)='object' AND octet_length(settings::text)<=65536)),
 author_id uuid, device_id uuid, client_key uuid, request_digest text,
 FOREIGN KEY(household_id,author_id) REFERENCES ritc.member,
 CHECK((author_id IS NULL AND device_id IS NULL AND client_key IS NULL AND request_digest IS NULL AND settings IS NULL)
     OR (author_id IS NOT NULL AND device_id IS NOT NULL AND client_key IS NOT NULL AND length(request_digest)=64))
);
ALTER TABLE ritc.meal_preference_profile ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.meal_preference_profile FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON ritc.meal_preference_profile TO ritc_app
 USING(household_id::text=(SELECT current_setting('app.household_id',true)))
 WITH CHECK(household_id::text=(SELECT current_setting('app.household_id',true)));
GRANT SELECT,INSERT,UPDATE ON ritc.meal_preference_profile TO ritc_app;
ALTER FUNCTION ritc.privacy_erase_extension(uuid,uuid) RENAME TO privacy_erase_before_meal_preferences;
CREATE FUNCTION ritc.privacy_erase_extension(h uuid,m uuid) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 PERFORM ritc.privacy_erase_before_meal_preferences(h,m);
 IF EXISTS(SELECT 1 FROM ritc.meal_preference_profile WHERE household_id=h AND author_id=m) THEN
  IF NOT ritc.privacy_erasure_authorized() THEN RAISE EXCEPTION 'erasure authority required'; END IF;
  UPDATE ritc.meal_preference_profile SET revision=gen_random_uuid(),settings=NULL,
   author_id=NULL,device_id=NULL,client_key=NULL,request_digest=NULL WHERE household_id=h AND author_id=m;
 END IF;
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_extension(uuid,uuid) FROM PUBLIC;
