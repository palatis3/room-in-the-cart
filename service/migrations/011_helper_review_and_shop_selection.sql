CREATE TABLE ritc.helper_mutation (
 household_id uuid NOT NULL, actor_id uuid NOT NULL, client_key uuid NOT NULL,
 mutation_id uuid NOT NULL, grant_id uuid NOT NULL, kind text NOT NULL CHECK(kind IN ('replace','resolve')),
 payload_digest text NOT NULL CHECK(length(payload_digest)=64), response jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(household_id,actor_id,client_key),
 FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member, FOREIGN KEY(household_id,grant_id) REFERENCES ritc.view_grant
);
ALTER TABLE ritc.helper_mutation ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.helper_mutation FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON ritc.helper_mutation USING(household_id::text=(SELECT current_setting('app.household_id',true))) WITH CHECK(household_id::text=(SELECT current_setting('app.household_id',true)));
CREATE INDEX helper_mutation_grant ON ritc.helper_mutation(household_id,grant_id);
GRANT SELECT,INSERT ON ritc.helper_mutation TO ritc_app;
ALTER TABLE ritc.helper_proposal ADD COLUMN revision integer NOT NULL DEFAULT 1 CHECK(revision>0);
ALTER TABLE ritc.helper_proposal ADD COLUMN resolution text CHECK(resolution IN ('replaced','dismissed'));
ALTER TABLE ritc.helper_proposal ADD COLUMN resolved_revision integer;
ALTER TABLE ritc.helper_proposal ADD COLUMN resolved_by uuid;
ALTER TABLE ritc.helper_proposal ADD COLUMN resolved_at timestamptz;
ALTER TABLE ritc.helper_proposal ADD COLUMN resolution_id uuid;
ALTER TABLE ritc.helper_proposal ADD FOREIGN KEY(household_id,resolved_by) REFERENCES ritc.member;
ALTER TABLE ritc.helper_proposal ADD CHECK((status='pending' AND resolved_at IS NULL AND resolution IS NULL AND resolved_revision IS NULL AND resolved_by IS NULL AND resolution_id IS NULL) OR (status<>'pending' AND resolved_at IS NOT NULL AND resolution IS NOT NULL AND resolved_revision>0 AND resolved_by IS NOT NULL AND resolution_id IS NOT NULL));
CREATE INDEX helper_proposal_resolver ON ritc.helper_proposal(household_id,resolved_by);
GRANT UPDATE(revision,status,resolution,resolved_revision,resolved_by,resolved_at,resolution_id) ON ritc.helper_proposal TO ritc_app;
ALTER TABLE ritc.web_session ADD COLUMN shop_id uuid;
ALTER TABLE ritc.web_session ADD FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop;
ALTER TABLE ritc.web_session ADD CHECK(grant_id IS NULL OR shop_id IS NULL);
CREATE INDEX web_session_shop ON ritc.web_session(household_id,shop_id);

-- Extend erasure for this slice without changing the frozen migration-010 implementation.
ALTER FUNCTION ritc.privacy_erase_target(uuid,uuid) RENAME TO privacy_erase_target_v010;
REVOKE ALL ON FUNCTION ritc.privacy_erase_target_v010(uuid,uuid) FROM ritc_worker;
CREATE FUNCTION ritc.privacy_erase_extension(target_household uuid,target_member uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN DELETE FROM ritc.helper_mutation WHERE household_id=target_household AND actor_id=target_member; END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_extension(uuid,uuid) FROM PUBLIC;
CREATE FUNCTION ritc.privacy_erase_target(request_id uuid,worker_lease uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE target record;result boolean;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM ritc.privacy_job WHERE job_id=request_id AND lease_id=worker_lease AND lease_until>clock_timestamp() AND state='processing') THEN RETURN false; END IF;
 SELECT household_id,member_id INTO target FROM ritc.privacy_target WHERE job_id=request_id AND erased_at IS NULL ORDER BY household_id,member_id LIMIT 1 FOR UPDATE;
 result=ritc.privacy_erase_target_v010(request_id,worker_lease);
 IF target.member_id IS NOT NULL THEN PERFORM ritc.privacy_erase_extension(target.household_id,target.member_id); END IF;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_target(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.privacy_erase_target(uuid,uuid) TO ritc_worker;
