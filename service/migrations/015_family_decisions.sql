CREATE TABLE ritc.family_decision (
 household_id uuid NOT NULL, decision_id uuid NOT NULL, shop_id uuid NOT NULL,
 author_id uuid NOT NULL, kind text NOT NULL CHECK(kind IN ('approval','exclusion','preference')),
 product text, dish text, occasion text, decision text NOT NULL, outcome text,
 recorded_at timestamptz NOT NULL, observed_at timestamptz, observer_id uuid,
 promoted_at timestamptz, promoter_id uuid, version integer NOT NULL DEFAULT 1 CHECK(version>0),
 PRIMARY KEY(household_id,decision_id),
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,
 FOREIGN KEY(household_id,author_id) REFERENCES ritc.member,
 FOREIGN KEY(household_id,observer_id) REFERENCES ritc.member,
 FOREIGN KEY(household_id,promoter_id) REFERENCES ritc.member,
 CHECK(num_nonnulls(product,dish,occasion)>0),
 CHECK(num_nonnulls(outcome,observed_at,observer_id) IN (0,3)),
 CHECK((promoted_at IS NULL)=(promoter_id IS NULL) AND (promoted_at IS NULL OR kind='preference'))
);
CREATE INDEX decision_by_shop ON ritc.family_decision(household_id,shop_id,recorded_at DESC,decision_id DESC);
CREATE INDEX decision_by_time ON ritc.family_decision(household_id,recorded_at DESC,decision_id DESC);
CREATE TABLE ritc.decision_receipt (
 household_id uuid NOT NULL, actor_id uuid NOT NULL, client_key uuid NOT NULL,
 decision_id uuid NOT NULL, fingerprint text NOT NULL, response jsonb,
 snapshot_observer uuid, snapshot_promoter uuid,
 PRIMARY KEY(household_id,actor_id,client_key),
 FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member,
 FOREIGN KEY(household_id,decision_id) REFERENCES ritc.family_decision ON DELETE CASCADE
);
CREATE INDEX decision_receipt_parent ON ritc.decision_receipt(household_id,decision_id);
DO $$ DECLARE t text; BEGIN FOREACH t IN ARRAY ARRAY['family_decision','decision_receipt'] LOOP
 EXECUTE format('ALTER TABLE ritc.%I ENABLE ROW LEVEL SECURITY',t);
 EXECUTE format('ALTER TABLE ritc.%I FORCE ROW LEVEL SECURITY',t);
 EXECUTE format('CREATE POLICY tenant_scope ON ritc.%I USING(household_id::text=(SELECT current_setting(''app.household_id'',true))) WITH CHECK(household_id::text=(SELECT current_setting(''app.household_id'',true)))',t);
 EXECUTE format('GRANT SELECT,INSERT ON ritc.%I TO ritc_app',t);
END LOOP; END $$;
GRANT UPDATE(version,outcome,observed_at,observer_id,promoted_at,promoter_id) ON ritc.family_decision TO ritc_app;

ALTER FUNCTION ritc.privacy_erase_extension(uuid,uuid) RENAME TO privacy_erase_meal_moves;
CREATE FUNCTION ritc.privacy_erase_extension(target_household uuid,target_member uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 DELETE FROM ritc.family_decision WHERE household_id=target_household AND author_id=target_member;
 DELETE FROM ritc.decision_receipt WHERE household_id=target_household AND actor_id=target_member;
 -- Invalidate even superseded snapshots held by other actors. A retry may never restore erased evidence.
 UPDATE ritc.decision_receipt SET response=NULL,snapshot_observer=NULL,snapshot_promoter=NULL
 WHERE household_id=target_household AND (snapshot_observer=target_member OR snapshot_promoter=target_member);
 UPDATE ritc.family_decision SET version=version+1,
   outcome=CASE WHEN observer_id=target_member THEN NULL ELSE outcome END,
   observed_at=CASE WHEN observer_id=target_member THEN NULL ELSE observed_at END,
   observer_id=CASE WHEN observer_id=target_member THEN NULL ELSE observer_id END,
   promoted_at=CASE WHEN promoter_id=target_member THEN NULL ELSE promoted_at END,
   promoter_id=CASE WHEN promoter_id=target_member THEN NULL ELSE promoter_id END
 WHERE household_id=target_household AND (observer_id=target_member OR promoter_id=target_member);
 PERFORM ritc.privacy_erase_meal_moves(target_household,target_member);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_extension(uuid,uuid) FROM PUBLIC;
