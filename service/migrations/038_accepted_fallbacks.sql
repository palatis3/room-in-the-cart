ALTER TABLE ritc.household ADD COLUMN fallback_revision integer NOT NULL DEFAULT 0 CHECK(fallback_revision>=0);
GRANT UPDATE(fallback_revision) ON ritc.household TO ritc_app;

-- New approvals and withdrawals append versions. Only privacy erasure can clear a version's content.
CREATE TABLE ritc.accepted_fallback_revision (
 household_id uuid NOT NULL REFERENCES ritc.household, candidate_id uuid NOT NULL, revision integer NOT NULL CHECK(revision>0),
 registry_revision integer NOT NULL CHECK(registry_revision>0), actor_id uuid NOT NULL, device_id uuid NOT NULL,
 client_key uuid NOT NULL, shop_id uuid NOT NULL, shop_revision integer NOT NULL, authority_epoch integer NOT NULL,
 accepted boolean NOT NULL, usual boolean NOT NULL, source jsonb, recipe jsonb, fingerprint text,
 source_members uuid[] NOT NULL, source_shops uuid[] NOT NULL, created_at timestamptz NOT NULL,
 PRIMARY KEY(household_id,candidate_id,revision), UNIQUE(household_id,registry_revision), UNIQUE(household_id,actor_id,client_key),
 FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member, FOREIGN KEY(household_id,device_id) REFERENCES ritc.device,
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,
 CHECK(fingerprint IS NULL OR fingerprint ~ '^[0-9a-f]{64}$'),
 CHECK((source IS NULL)=(recipe IS NULL)), CHECK(recipe IS NULL OR accepted),
 CHECK(NOT usual OR accepted), CHECK(fingerprint IS NULL OR NOT accepted OR recipe IS NOT NULL)
);
CREATE INDEX fallback_source_members ON ritc.accepted_fallback_revision USING gin(source_members);
CREATE INDEX fallback_source_shops ON ritc.accepted_fallback_revision USING gin(source_shops);

CREATE TABLE ritc.meal_recovery_fallback (
 household_id uuid NOT NULL, operation_id uuid NOT NULL, candidate_id uuid NOT NULL, revision integer NOT NULL,
 PRIMARY KEY(household_id,operation_id),
 FOREIGN KEY(household_id,operation_id) REFERENCES ritc.meal_recovery_revision(household_id,operation_id) ON DELETE CASCADE,
 FOREIGN KEY(household_id,candidate_id,revision) REFERENCES ritc.accepted_fallback_revision
);
DO $$
DECLARE tab text;
BEGIN
 FOREACH tab IN ARRAY ARRAY['accepted_fallback_revision','meal_recovery_fallback'] LOOP
  EXECUTE format('ALTER TABLE ritc.%I ENABLE ROW LEVEL SECURITY',tab);
  EXECUTE format('ALTER TABLE ritc.%I FORCE ROW LEVEL SECURITY',tab);
  EXECUTE format('CREATE POLICY tenant_scope ON ritc.%I TO ritc_app USING(household_id::text=(SELECT current_setting(''app.household_id'',true))) WITH CHECK(household_id::text=(SELECT current_setting(''app.household_id'',true)))',tab);
  EXECUTE format('GRANT SELECT,INSERT ON ritc.%I TO ritc_app',tab);
 END LOOP;
END $$;

CREATE FUNCTION ritc.redact_accepted_fallbacks(house uuid, actor uuid, source_shop uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 UPDATE ritc.accepted_fallback_revision SET source=NULL,recipe=NULL,fingerprint=NULL,source_members='{}',source_shops='{}'
 WHERE household_id=house AND fingerprint IS NOT NULL AND
 ((actor IS NOT NULL AND (actor_id=actor OR source_members @> ARRAY[actor])) OR
  (source_shop IS NOT NULL AND source_shops @> ARRAY[source_shop]));
 IF FOUND THEN UPDATE ritc.household SET fallback_revision=fallback_revision+1 WHERE household_id=house; END IF;
END $$;
REVOKE ALL ON FUNCTION ritc.redact_accepted_fallbacks(uuid,uuid,uuid) FROM PUBLIC;
CREATE FUNCTION ritc.redact_fallback_snapshot() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN PERFORM ritc.redact_accepted_fallbacks(NEW.household_id,NULL,NEW.shop_id); RETURN NULL; END $$;
REVOKE ALL ON FUNCTION ritc.redact_fallback_snapshot() FROM PUBLIC;
CREATE TRIGGER redact_fallback_snapshot AFTER UPDATE OF snapshot ON ritc.shop_snapshot FOR EACH ROW
 WHEN (OLD.snapshot IS DISTINCT FROM NEW.snapshot) EXECUTE FUNCTION ritc.redact_fallback_snapshot();
ALTER FUNCTION ritc.privacy_erase_extension(uuid,uuid) RENAME TO privacy_erase_before_accepted_fallbacks;
CREATE FUNCTION ritc.privacy_erase_extension(target_household uuid,target_member uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 PERFORM ritc.redact_accepted_fallbacks(target_household,target_member,NULL);
 PERFORM ritc.privacy_erase_before_accepted_fallbacks(target_household,target_member);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_extension(uuid,uuid) FROM PUBLIC;
