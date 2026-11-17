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

ALTER TABLE ritc.shared_meal_idea ADD COLUMN preference_revision uuid;

CREATE TABLE ritc.meal_preference_profile (
 household_id uuid PRIMARY KEY REFERENCES ritc.household,
 revision uuid NOT NULL,
 settings jsonb CHECK(settings IS NULL OR (jsonb_typeof(settings)='object' AND octet_length(settings::text)<=65536)),
 rule_authors jsonb NOT NULL CHECK(jsonb_typeof(rule_authors)='object')
);
ALTER TABLE ritc.meal_preference_profile ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.meal_preference_profile FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON ritc.meal_preference_profile TO ritc_app
 USING(household_id::text=(SELECT current_setting('app.household_id',true)))
 WITH CHECK(household_id::text=(SELECT current_setting('app.household_id',true)));
GRANT SELECT,INSERT,UPDATE ON ritc.meal_preference_profile TO ritc_app;
CREATE TABLE ritc.meal_preference_write_key (
 household_id uuid NOT NULL REFERENCES ritc.household,
 client_key uuid NOT NULL,
 actor_id uuid NOT NULL, device_id uuid NOT NULL, window_id uuid NOT NULL,
 accepted_revision uuid NOT NULL, request_digest text NOT NULL CHECK(length(request_digest)=64),
 PRIMARY KEY(household_id,client_key),
 FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member
);
ALTER TABLE ritc.meal_preference_write_key ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.meal_preference_write_key FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON ritc.meal_preference_write_key TO ritc_app
 USING(household_id::text=(SELECT current_setting('app.household_id',true)))
 WITH CHECK(household_id::text=(SELECT current_setting('app.household_id',true)));
GRANT SELECT,INSERT,DELETE ON ritc.meal_preference_write_key TO ritc_app;
ALTER FUNCTION ritc.privacy_erase_extension(uuid,uuid) RENAME TO privacy_erase_before_meal_preferences;
CREATE FUNCTION ritc.privacy_erase_extension(h uuid,m uuid) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE previous ritc.meal_preference_profile%ROWTYPE; amended jsonb; authors jsonb; k text; retained jsonb;
BEGIN
 PERFORM ritc.privacy_erase_before_meal_preferences(h,m);
 IF EXISTS(SELECT 1 FROM ritc.meal_preference_write_key WHERE household_id=h AND actor_id=m) THEN
  IF NOT ritc.privacy_erasure_authorized() THEN RAISE EXCEPTION 'erasure authority required'; END IF;
  DELETE FROM ritc.meal_preference_write_key WHERE household_id=h AND actor_id=m;
 END IF;
 SELECT * INTO previous FROM ritc.meal_preference_profile WHERE household_id=h FOR UPDATE;
 IF NOT FOUND THEN RETURN; END IF;
 IF NOT EXISTS(
  SELECT 1 FROM jsonb_each(previous.rule_authors) field CROSS JOIN LATERAL jsonb_each(field.value) attribution
  WHERE attribution.value ? m::text) THEN RETURN; END IF;
 IF NOT ritc.privacy_erasure_authorized() THEN RAISE EXCEPTION 'erasure authority required'; END IF;
 amended:=previous.settings;
 SELECT COALESCE(jsonb_object_agg(field.key,COALESCE((SELECT jsonb_object_agg(a.key,a.value)
   FROM jsonb_each(field.value) a WHERE NOT (a.value ? m::text)),'{}'::jsonb)),'{}'::jsonb)
   INTO authors FROM jsonb_each(previous.rule_authors) field;
 IF amended IS NOT NULL THEN
  FOREACH k IN ARRAY ARRAY['exclusions','availableAppliances','dislikes','preferredBrands'] LOOP
   IF jsonb_typeof(amended->k)='array' THEN
    SELECT COALESCE(jsonb_agg(v ORDER BY ord),'[]'::jsonb) INTO retained
      FROM jsonb_array_elements_text(amended->k) WITH ORDINALITY a(v,ord)
      WHERE (authors->k) ? v;
    amended:=jsonb_set(amended,ARRAY[k],retained);
   END IF;
  END LOOP;
  IF amended->'availableAppliances'='[]'::jsonb AND NOT COALESCE((authors->'appliancesReviewed') ? 'yes',false) THEN
   amended:=amended-'availableAppliances';
  END IF;
  IF NOT COALESCE((authors->'maximumEffort') ? (amended->>'maximumEffort'),false) THEN amended:=amended-'maximumEffort'; END IF;
  FOREACH k IN ARRAY ARRAY['strictDislikes','strictBrands','strictEffort'] LOOP
   IF NOT COALESCE((authors->k) ? 'true',false)
    OR (k='strictDislikes' AND amended->'dislikes'='[]'::jsonb)
    OR (k='strictBrands' AND amended->'preferredBrands'='[]'::jsonb)
    OR (k='strictEffort' AND amended->>'maximumEffort' IS NULL) THEN
     amended:=jsonb_set(amended,ARRAY[k],'false'::jsonb);authors:=authors-k;
   END IF;
  END LOOP;
  IF amended->'exclusions'='[]'::jsonb AND amended->'dislikes'='[]'::jsonb AND amended->'preferredBrands'='[]'::jsonb
   AND amended->>'availableAppliances' IS NULL AND amended->>'maximumEffort' IS NULL THEN amended:=NULL;authors:='{}'::jsonb; END IF;
 END IF;
 UPDATE ritc.meal_preference_profile SET revision=gen_random_uuid(),settings=amended,rule_authors=authors WHERE household_id=h;
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_extension(uuid,uuid) FROM PUBLIC;
