-- A recovery changes what the household will cook. The placed snapshot and its
-- meal revisions remain the record of what the shopper ordered.
ALTER TABLE ritc.shop ADD COLUMN recovery_revision integer NOT NULL DEFAULT 0 CHECK(recovery_revision>=0);
-- Only the digest of an authenticated, short-lived preview is retained. An
-- expired receipt cannot authorize a different actor, device or decision.
CREATE TABLE ritc.meal_recovery_preview (
 household_id uuid NOT NULL, shop_id uuid NOT NULL, preview_id uuid NOT NULL, actor_id uuid NOT NULL, device_id uuid NOT NULL,
 digest text NOT NULL CHECK(digest ~ '^[0-9a-f]{64}$'), expires_at timestamptz NOT NULL,
 PRIMARY KEY(household_id,preview_id),
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,
 FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member,
 FOREIGN KEY(household_id,device_id) REFERENCES ritc.device
);
CREATE INDEX meal_recovery_preview_expiry ON ritc.meal_recovery_preview(household_id,expires_at);
CREATE TABLE ritc.meal_recovery_revision (
 household_id uuid NOT NULL, shop_id uuid NOT NULL, recovery_revision integer NOT NULL CHECK(recovery_revision>0),
 operation_id uuid NOT NULL, occurrence_id uuid NOT NULL, source_meal_revision integer NOT NULL,
 previous_revision_id uuid NOT NULL, new_revision_id uuid NOT NULL,
 placed_revision integer NOT NULL, authority_epoch integer NOT NULL, supply_revision integer NOT NULL, pantry_revision integer NOT NULL,
 actor_id uuid NOT NULL, created_at timestamptz NOT NULL,
 current_meal jsonb, intent jsonb, decision_digest text, need_ids uuid[] NOT NULL,
 PRIMARY KEY(household_id,shop_id,recovery_revision),
 UNIQUE(household_id,operation_id), UNIQUE(household_id,shop_id,new_revision_id),
 FOREIGN KEY(household_id,operation_id) REFERENCES ritc.operation DEFERRABLE INITIALLY DEFERRED,
 FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member,
 FOREIGN KEY(household_id,shop_id,placed_revision) REFERENCES ritc.shop_snapshot,
 FOREIGN KEY(household_id,shop_id,occurrence_id,source_meal_revision) REFERENCES ritc.shared_meal_revision ON DELETE CASCADE,
 CHECK(previous_revision_id<>new_revision_id),
 CHECK((current_meal IS NULL)=(intent IS NULL) AND (current_meal IS NULL)=(decision_digest IS NULL)),
 CHECK(decision_digest IS NULL OR decision_digest ~ '^[0-9a-f]{64}$')
);
ALTER TABLE ritc.dated_cook_copy
 ADD COLUMN recovery_revision integer CHECK(recovery_revision>0),
 ADD COLUMN recovery_meal_id uuid,
 ADD CHECK ((recovery_revision IS NULL)=(recovery_meal_id IS NULL)),
 ADD FOREIGN KEY(household_id,shop_id,recovery_meal_id)
  REFERENCES ritc.meal_recovery_revision(household_id,shop_id,new_revision_id) ON DELETE CASCADE;
CREATE INDEX dated_cook_copy_recovery ON ritc.dated_cook_copy(household_id,shop_id,recovery_meal_id)
 WHERE recovery_meal_id IS NOT NULL;
CREATE INDEX meal_recovery_head ON ritc.meal_recovery_revision(household_id,shop_id,occurrence_id,recovery_revision DESC);
CREATE INDEX meal_recovery_author ON ritc.meal_recovery_revision(household_id,actor_id);
-- Private provenance captures contributors and connected shops at publication.
-- A later stock selection cannot change the sources of a previously saved decision.
CREATE TABLE ritc.meal_recovery_source_member (
 household_id uuid NOT NULL, operation_id uuid NOT NULL, member_id uuid NOT NULL,
 PRIMARY KEY(household_id,operation_id,member_id),
 FOREIGN KEY(household_id,operation_id) REFERENCES ritc.meal_recovery_revision(household_id,operation_id) ON DELETE CASCADE,
 FOREIGN KEY(household_id,member_id) REFERENCES ritc.member
);
CREATE INDEX meal_recovery_member_lookup ON ritc.meal_recovery_source_member(household_id,member_id);
CREATE TABLE ritc.meal_recovery_source_shop (
 household_id uuid NOT NULL, operation_id uuid NOT NULL, shop_id uuid NOT NULL,
 PRIMARY KEY(household_id,operation_id,shop_id),
 FOREIGN KEY(household_id,operation_id) REFERENCES ritc.meal_recovery_revision(household_id,operation_id) ON DELETE CASCADE,
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop
);
CREATE INDEX meal_recovery_shop_lookup ON ritc.meal_recovery_source_shop(household_id,shop_id);

DO $$
DECLARE relation text;
BEGIN
 FOREACH relation IN ARRAY ARRAY['meal_recovery_preview','meal_recovery_revision','meal_recovery_source_member','meal_recovery_source_shop'] LOOP
  EXECUTE format('ALTER TABLE ritc.%I ENABLE ROW LEVEL SECURITY',relation);
  EXECUTE format('ALTER TABLE ritc.%I FORCE ROW LEVEL SECURITY',relation);
  EXECUTE format('CREATE POLICY tenant_scope ON ritc.%I TO ritc_app USING(household_id::text=(SELECT current_setting(''app.household_id'',true))) WITH CHECK(household_id::text=(SELECT current_setting(''app.household_id'',true)))',relation);
 END LOOP;
END $$;
GRANT SELECT,INSERT ON ritc.meal_recovery_revision,ritc.meal_recovery_source_member,ritc.meal_recovery_source_shop TO ritc_app;
GRANT SELECT,INSERT,DELETE ON ritc.meal_recovery_preview TO ritc_app;
GRANT UPDATE(recovery_revision) ON ritc.shop TO ritc_app;

-- Remove derived wording and every later version of that meal. Keep a
-- content-free head so readers do not silently revert to an older dinner.
CREATE FUNCTION ritc.redact_meal_recoveries(house uuid, source_member uuid, source_shop uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 WITH affected AS (
  SELECT r.shop_id,r.occurrence_id,min(r.recovery_revision) AS first_revision
  FROM ritc.meal_recovery_revision r
  WHERE r.household_id=house AND r.current_meal IS NOT NULL AND (
   r.actor_id=source_member OR EXISTS(SELECT FROM ritc.meal_recovery_source_member m
    WHERE (m.household_id,m.operation_id,m.member_id)=(house,r.operation_id,source_member)) OR
   EXISTS(SELECT FROM ritc.meal_recovery_source_shop s
    WHERE (s.household_id,s.operation_id,s.shop_id)=(house,r.operation_id,source_shop)))
  GROUP BY r.shop_id,r.occurrence_id
 ), removed AS (
  UPDATE ritc.meal_recovery_revision r SET current_meal=NULL,intent=NULL,decision_digest=NULL
  FROM affected a WHERE r.household_id=house AND (r.shop_id,r.occurrence_id)=(a.shop_id,a.occurrence_id)
   AND r.recovery_revision>=a.first_revision AND r.current_meal IS NOT NULL
  RETURNING r.shop_id,r.occurrence_id,r.created_at
 ), deleted_copies AS (
  DELETE FROM ritc.dated_cook_copy c USING removed r WHERE c.household_id=house
   AND (c.shop_id,c.occurrence_id)=(r.shop_id,r.occurrence_id) AND c.created_at>=r.created_at
 )
 UPDATE ritc.shop SET recovery_revision=recovery_revision+1,supply_revision=supply_revision+1
 WHERE household_id=house AND shop_id IN (SELECT shop_id FROM removed);
END $$;
REVOKE ALL ON FUNCTION ritc.redact_meal_recoveries(uuid,uuid,uuid) FROM PUBLIC;

CREATE FUNCTION ritc.redact_recovery_snapshot() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 PERFORM ritc.redact_meal_recoveries(NEW.household_id,NULL,NEW.shop_id);
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION ritc.redact_recovery_snapshot() FROM PUBLIC;
CREATE TRIGGER redact_recovery_snapshot AFTER UPDATE OF snapshot ON ritc.shop_snapshot FOR EACH ROW
 WHEN(OLD.snapshot IS DISTINCT FROM NEW.snapshot) EXECUTE FUNCTION ritc.redact_recovery_snapshot();

ALTER FUNCTION ritc.privacy_erase_extension(uuid,uuid) RENAME TO privacy_erase_before_meal_recovery;
CREATE FUNCTION ritc.privacy_erase_extension(target_household uuid,target_member uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 DELETE FROM ritc.meal_recovery_preview WHERE household_id=target_household AND actor_id=target_member;
 PERFORM ritc.redact_meal_recoveries(target_household,target_member,NULL);
 PERFORM ritc.privacy_erase_before_meal_recovery(target_household,target_member);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_extension(uuid,uuid) FROM PUBLIC;
