-- Only the owning recovery operator may retire a drained historical generation.
-- Ordinary mutation of these three append-only tables remains forbidden.
-- The recovery connection must see the complete scoped inventory even when its
-- schema owner is an ordinary NOBYPASSRLS role. These policies grant no SQL
-- privileges and apply only to each table's existing owner.
DO $$ DECLARE t text; owner_name name; BEGIN
 FOREACH t IN ARRAY ARRAY['privacy_job','privacy_target','identity_erasure','privacy_journal_origin',
   'privacy_journal_outbox','privacy_journal_target','privacy_journal_ack','privacy_restore_run','privacy_restore_job'] LOOP
  SELECT pg_get_userbyid(relowner) INTO STRICT owner_name FROM pg_class WHERE oid=format('ritc.%I',t)::regclass;
  EXECUTE format('CREATE POLICY journal_retirement_owner ON ritc.%I TO %I USING(true) WITH CHECK(true)',t,owner_name);
 END LOOP;
END $$;
CREATE TABLE ritc.privacy_source_replay_clock(lineage uuid PRIMARY KEY, original_capture timestamptz NOT NULL);
ALTER TABLE ritc.privacy_source_replay_clock ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.privacy_source_replay_clock FORCE ROW LEVEL SECURITY;
DO $$ DECLARE role_name name; BEGIN
 EXECUTE format('CREATE POLICY owner_scope ON ritc.privacy_source_replay_clock TO %I USING(true) WITH CHECK(true)',current_user);
 REVOKE ALL ON ritc.privacy_source_replay_clock FROM PUBLIC;
 FOR role_name IN SELECT rolname FROM pg_roles WHERE rolname IN ('ritc_app','ritc_worker','anon','authenticated','service_role') LOOP
  EXECUTE format('REVOKE ALL ON ritc.privacy_source_replay_clock FROM %I',role_name);
 END LOOP;
END $$;
INSERT INTO ritc.privacy_source_replay_clock
 SELECT lineage,min(least(created_at,(payload#>>'{data,acceptedAt}')::timestamptz,(payload#>>'{data,attestation,checkedAt}')::timestamptz))
 FROM ritc.privacy_journal_outbox WHERE kind='acceptance' GROUP BY lineage;

CREATE FUNCTION ritc.privacy_reject_retired_generation() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE original timestamptz;
BEGIN
 IF TG_RELID<>'ritc.privacy_journal_outbox'::regclass THEN RAISE EXCEPTION 'invalid trigger source'; END IF;
 PERFORM FROM ritc.privacy_journal_origin WHERE singleton AND lineage=NEW.lineage AND NOT fenced FOR SHARE;
 IF NOT FOUND OR EXISTS(SELECT FROM ritc.privacy_journal_rotation WHERE predecessor=NEW.lineage) THEN
  RAISE EXCEPTION 'inactive source generation';
 END IF;
 IF NEW.kind='acceptance' THEN
  -- The outbox insertion timestamp is an additional conservative witness for
  -- historical source event shapes. Current signed intents carry both clocks.
  original=least(NEW.created_at,(NEW.payload#>>'{data,acceptedAt}')::timestamptz,(NEW.payload#>>'{data,attestation,checkedAt}')::timestamptz);
  INSERT INTO ritc.privacy_source_replay_clock VALUES(NEW.lineage,original) ON CONFLICT(lineage) DO UPDATE
    SET original_capture=least(ritc.privacy_source_replay_clock.original_capture,EXCLUDED.original_capture)
    RETURNING original_capture INTO original;
 ELSE
  SELECT original_capture INTO original FROM ritc.privacy_source_replay_clock WHERE lineage=NEW.lineage;
 END IF;
 IF original+interval '2160 hours'<=clock_timestamp() THEN RAISE EXCEPTION 'overdue source generation'; END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_reject_retired_generation() FROM PUBLIC,ritc_app,ritc_worker;
CREATE TRIGGER reject_retired_generation BEFORE INSERT ON ritc.privacy_journal_outbox
FOR EACH ROW EXECUTE FUNCTION ritc.privacy_reject_retired_generation();

CREATE FUNCTION ritc.privacy_journal_retirement_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE generation uuid;
BEGIN
 IF TG_OP='DELETE' AND current_user=session_user
    AND session_user=pg_get_userbyid((SELECT relowner FROM pg_class WHERE oid=TG_RELID)) THEN
  IF TG_TABLE_NAME='privacy_journal_outbox' THEN
   generation=OLD.lineage;
  ELSE
   SELECT e.lineage INTO generation FROM ritc.privacy_journal_outbox e WHERE e.event_id=OLD.event_id;
  END IF;
  IF generation::text=current_setting('ritc.retiring_generation',true)
     AND EXISTS(SELECT FROM ritc.privacy_journal_rotation WHERE predecessor=generation)
     AND NOT EXISTS(SELECT FROM ritc.privacy_journal_origin WHERE lineage=generation) THEN
   RETURN OLD;
  END IF;
 END IF;
 RAISE EXCEPTION 'immutable journal';
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_journal_retirement_guard() FROM PUBLIC,ritc_app,ritc_worker;

DROP TRIGGER immutable_journal ON ritc.privacy_journal_outbox;
CREATE TRIGGER immutable_journal BEFORE UPDATE OR DELETE ON ritc.privacy_journal_outbox
FOR EACH ROW EXECUTE FUNCTION ritc.privacy_journal_retirement_guard();
DROP TRIGGER immutable_journal_target ON ritc.privacy_journal_target;
CREATE TRIGGER immutable_journal_target BEFORE UPDATE OR DELETE ON ritc.privacy_journal_target
FOR EACH ROW EXECUTE FUNCTION ritc.privacy_journal_retirement_guard();
DROP TRIGGER immutable_journal_ack ON ritc.privacy_journal_ack;
CREATE TRIGGER immutable_journal_ack BEFORE UPDATE OR DELETE ON ritc.privacy_journal_ack
FOR EACH ROW EXECUTE FUNCTION ritc.privacy_journal_retirement_guard();

CREATE FUNCTION ritc.privacy_retire_journal_source(generation uuid, seal_digest text, recovered_capture timestamptz)
RETURNS bigint LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog AS $$
DECLARE rotated ritc.privacy_journal_rotation; removed bigint; cutoff timestamptz:=clock_timestamp();
BEGIN
 IF current_user<>session_user OR session_user<>pg_get_userbyid((SELECT relowner FROM pg_class
   WHERE oid='ritc.privacy_journal_outbox'::regclass)) OR pg_is_in_recovery() THEN
  RAISE EXCEPTION 'retirement requires source owner';
 END IF;
 PERFORM FROM ritc.privacy_journal_origin WHERE singleton AND lineage<>generation FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'cannot retire current or unregistered source'; END IF;
 SELECT * INTO STRICT rotated FROM ritc.privacy_journal_rotation WHERE predecessor=generation;
 IF rotated.proof->>'predecessorSealDigest' IS DISTINCT FROM seal_digest
    OR rotated.proof->>'sourceDatabaseOid' IS DISTINCT FROM (SELECT oid::text FROM pg_database WHERE datname=current_database())
    OR NOT EXISTS(SELECT FROM ritc.privacy_journal_source_registration WHERE singleton
       AND database_oid=(SELECT oid FROM pg_database WHERE datname=current_database())
       AND source_identity=rotated.proof->>'sourceIdentity')
    OR recovered_capture IS NULL OR recovered_capture<=rotated.activated_at OR recovered_capture>clock_timestamp()
    OR recovered_capture+interval '720 hours'<=clock_timestamp()
    OR rotated.activated_at+interval '720 hours'>clock_timestamp() THEN
  RAISE EXCEPTION 'rotation or recoverable snapshot window pending';
 END IF;
 LOCK TABLE ritc.privacy_journal_outbox,ritc.privacy_journal_target,ritc.privacy_journal_ack IN SHARE ROW EXCLUSIVE MODE;
 IF EXISTS(SELECT FROM ritc.privacy_restore_run) OR EXISTS(
   SELECT FROM ritc.privacy_journal_outbox e LEFT JOIN ritc.privacy_journal_ack a USING(event_id)
   LEFT JOIN ritc.privacy_job j USING(job_id)
   WHERE e.lineage=generation AND (a.payload_digest IS DISTINCT FROM e.payload_digest
     OR (j.job_id IS NOT NULL AND (j.state<>'complete' OR j.provider_erased_at IS NULL OR j.receipt_until>clock_timestamp())))) THEN
  RAISE EXCEPTION 'source receipts, recovery or acknowledgements pending';
 END IF;
 IF EXISTS(SELECT FROM ritc.privacy_journal_outbox a JOIN ritc.privacy_journal_outbox b USING(job_id)
   WHERE a.lineage=generation AND b.lineage<>generation) THEN RAISE EXCEPTION 'job spans generations'; END IF;
 -- Detailed replay and the anti-resurrection marker have separate lifetimes.
 -- Retiring a lineage clears expired receipt material and detailed targets. Keep
 -- the minimal completed job/identity marker for normal cleanup at its own clock.
 DELETE FROM ritc.privacy_target t USING ritc.privacy_journal_outbox e WHERE e.lineage=generation AND e.job_id=t.job_id;
 UPDATE ritc.privacy_job j SET receipt_hash=repeat('0',64),payload_digest=repeat('0',64),
   marker_until=greatest(j.marker_until,(SELECT max(i.retain_until) FROM ritc.identity_erasure i WHERE i.job_id=j.job_id))
 WHERE EXISTS(SELECT FROM ritc.privacy_journal_outbox e WHERE e.lineage=generation AND e.job_id=j.job_id);
 DELETE FROM ritc.identity_erasure i USING ritc.privacy_job j WHERE i.job_id=j.job_id AND j.marker_until<=cutoff
   AND EXISTS(SELECT FROM ritc.privacy_journal_outbox e WHERE e.lineage=generation AND e.job_id=j.job_id);
 DELETE FROM ritc.privacy_job j WHERE j.marker_until<=cutoff
   AND EXISTS(SELECT FROM ritc.privacy_journal_outbox e WHERE e.lineage=generation AND e.job_id=j.job_id);
 PERFORM set_config('ritc.retiring_generation',generation::text,true);
 DELETE FROM ritc.privacy_journal_target t USING ritc.privacy_journal_outbox e WHERE e.lineage=generation AND e.event_id=t.event_id;
 DELETE FROM ritc.privacy_journal_ack a USING ritc.privacy_journal_outbox e WHERE e.lineage=generation AND e.event_id=a.event_id;
 DELETE FROM ritc.privacy_journal_outbox WHERE lineage=generation;
 GET DIAGNOSTICS removed=ROW_COUNT;
 DELETE FROM ritc.privacy_source_replay_clock WHERE lineage=generation;
 PERFORM set_config('ritc.retiring_generation','',true);
 RETURN removed;
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_retire_journal_source(uuid,text,timestamptz) FROM PUBLIC,ritc_app,ritc_worker;
