-- The source owner installs an independently verified link during cutover.
-- Historical outbox and acknowledgement rows stay in place.
CREATE TABLE ritc.privacy_journal_rotation (
 predecessor uuid PRIMARY KEY,
 successor uuid UNIQUE NOT NULL,
 successor_schema_digest text NOT NULL CHECK(successor_schema_digest ~ '^[0-9a-f]{64}$'),
 successor_configuration_id text NOT NULL CHECK(length(successor_configuration_id) BETWEEN 1 AND 100),
 proof jsonb NOT NULL,
 activated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 CHECK(predecessor<>successor)
);
ALTER TABLE ritc.privacy_journal_rotation ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.privacy_journal_rotation FORCE ROW LEVEL SECURITY;
DO $$ BEGIN
 EXECUTE format('CREATE POLICY owner_scope ON ritc.privacy_journal_rotation TO %I USING(true) WITH CHECK(true)',current_user);
END $$;
REVOKE ALL ON ritc.privacy_journal_rotation FROM PUBLIC,ritc_app,ritc_worker;
CREATE TRIGGER immutable_rotation BEFORE UPDATE OR DELETE ON ritc.privacy_journal_rotation
 FOR EACH ROW EXECUTE FUNCTION ritc.privacy_journal_immutable();
CREATE TRIGGER immutable_journal_ack BEFORE UPDATE OR DELETE ON ritc.privacy_journal_ack
 FOR EACH ROW EXECUTE FUNCTION ritc.privacy_journal_immutable();
CREATE INDEX privacy_journal_outbox_lineage ON ritc.privacy_journal_outbox(lineage);

CREATE FUNCTION ritc.privacy_journal_drained() RETURNS boolean
LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
 SELECT NOT EXISTS(SELECT 1 FROM ritc.privacy_restore_run)
  AND NOT EXISTS(SELECT 1 FROM ritc.privacy_job WHERE state<>'complete')
  AND NOT EXISTS(SELECT 1 FROM ritc.privacy_journal_outbox e
   WHERE NOT EXISTS(SELECT 1 FROM ritc.privacy_journal_ack a WHERE a.event_id=e.event_id AND a.payload_digest=e.payload_digest))
$$;
REVOKE ALL ON FUNCTION ritc.privacy_journal_drained() FROM PUBLIC,ritc_app,ritc_worker;

CREATE OR REPLACE FUNCTION ritc.privacy_journal_origin_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF TG_OP='UPDATE' THEN
  IF (to_jsonb(NEW)-'fenced')=(to_jsonb(OLD)-'fenced') AND (NOT OLD.fenced OR NEW.fenced) THEN RETURN NEW; END IF;
  IF OLD.fenced AND NOT NEW.fenced AND OLD.lineage<>NEW.lineage AND NEW.singleton=OLD.singleton
   AND NEW.registered_at=OLD.registered_at AND current_user=session_user
   AND current_user=(SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid=TG_RELID)
   AND NOT pg_is_in_recovery()
  THEN
   IF EXISTS(
    SELECT 1 FROM ritc.privacy_journal_rotation l CROSS JOIN ritc.privacy_journal_source_registration s
    WHERE l.predecessor=OLD.lineage AND l.successor=NEW.lineage AND s.singleton
     AND l.successor_schema_digest=NEW.schema_digest AND l.successor_configuration_id=NEW.configuration_id
     AND s.database_oid=(SELECT oid FROM pg_database WHERE datname=current_database())
     AND l.proof->>'predecessorLineage'=OLD.lineage::text AND l.proof->>'successorLineage'=NEW.lineage::text
     AND l.proof->>'sourceIdentity'=s.source_identity AND l.proof->>'sourceDatabaseOid'=s.database_oid::text
   ) AND ritc.privacy_journal_drained() THEN RETURN NEW; END IF;
  END IF;
 END IF;
 RAISE EXCEPTION 'immutable journal origin';
END $$;

-- Preserve the existing receipt DTO. The archive flag is internal to the
-- trusted application, with the same receipt-token gate as the DTO itself.
CREATE FUNCTION ritc.privacy_status_for_journal(request_id uuid,receipt text)
RETURNS TABLE(value jsonb,archived boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT s.value,COALESCE(s.value->>'status'='complete',false) AND EXISTS(
  SELECT 1 FROM ritc.privacy_journal_outbox e JOIN ritc.privacy_journal_rotation r ON r.predecessor=e.lineage
  WHERE e.job_id=request_id AND e.kind='acceptance'
 )
 FROM ritc.privacy_status(request_id,receipt) AS s(value)
$$;
REVOKE ALL ON FUNCTION ritc.privacy_status_for_journal(uuid,text) FROM PUBLIC,ritc_worker;
GRANT EXECUTE ON FUNCTION ritc.privacy_status_for_journal(uuid,text) TO ritc_app;

-- A worker may have passed its readiness probe immediately before rollover.
-- Bind both durable claim paths under the same source-row lock as the switch.
CREATE FUNCTION ritc.privacy_claim(worker_lease uuid,expected_lineage uuid)
RETURNS TABLE(job_id uuid,issuer text,subject text,app_erased boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 PERFORM 1 FROM ritc.privacy_journal_origin WHERE singleton AND lineage=expected_lineage AND NOT fenced FOR SHARE;
 IF NOT FOUND THEN RETURN; END IF;
 RETURN QUERY SELECT * FROM ritc.privacy_claim(worker_lease);
END $$;
CREATE FUNCTION ritc.privacy_claim_reconciliation(worker_lease uuid,expected_lineage uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 PERFORM 1 FROM ritc.privacy_journal_origin WHERE singleton AND lineage=expected_lineage AND NOT fenced FOR SHARE;
 IF NOT FOUND THEN RETURN NULL; END IF;
 RETURN ritc.privacy_claim_reconciliation(worker_lease);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_claim(uuid,uuid),ritc.privacy_claim_reconciliation(uuid,uuid) FROM PUBLIC,ritc_app;
GRANT EXECUTE ON FUNCTION ritc.privacy_claim(uuid,uuid),ritc.privacy_claim_reconciliation(uuid,uuid) TO ritc_worker;
