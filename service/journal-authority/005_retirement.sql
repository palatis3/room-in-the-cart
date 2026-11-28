BEGIN;
-- One aggregate original timestamp per technical scope. This contains no job,
-- subject, target, event ID, address or record content.
CREATE TABLE ritc_checkpoint.replay_clock(
 scope_digest text PRIMARY KEY REFERENCES ritc_checkpoint.origin(scope_digest),
 original_capture timestamptz NOT NULL
);
REVOKE ALL ON ritc_checkpoint.replay_clock FROM PUBLIC,ritc_record_runtime,ritc_checkpoint_runtime;

-- A pathname belongs to the custodian. The authority stores only a technical
-- locator digest, payload digest and scope while the export remains outstanding.
CREATE TABLE ritc_checkpoint.detail_export(
 scope_digest text NOT NULL REFERENCES ritc_checkpoint.origin(scope_digest),
 custodian_id uuid NOT NULL,
 locator_digest text NOT NULL CHECK(locator_digest ~ '^[0-9a-f]{64}$'),
 content_digest text NOT NULL CHECK(content_digest ~ '^[0-9a-f]{64}$'),
 PRIMARY KEY(scope_digest,locator_digest)
);
REVOKE ALL ON ritc_checkpoint.detail_export FROM PUBLIC,ritc_record_runtime,ritc_checkpoint_runtime;

DO $$ DECLARE t text; n name; BEGIN
 FOREACH t IN ARRAY ARRAY['replay_clock','detail_export'] LOOP
  EXECUTE format('ALTER TABLE ritc_checkpoint.%I ENABLE ROW LEVEL SECURITY',t);
  EXECUTE format('ALTER TABLE ritc_checkpoint.%I FORCE ROW LEVEL SECURITY',t);
  EXECUTE format('CREATE POLICY owner_scope ON ritc_checkpoint.%I TO %I USING(true) WITH CHECK(true)',t,current_user);
  FOR n IN SELECT rolname FROM pg_roles WHERE rolname IN ('anon','authenticated','service_role') LOOP
   EXECUTE format('REVOKE ALL ON ritc_checkpoint.%I FROM %I',t,n);
  END LOOP;
 END LOOP;
END $$;

-- Preserve the timestamp of pre-installation objects, including orphaned intents.
WITH objects AS (
 SELECT split_part(object_key,'/',1) AS scope,convert_from(content,'UTF8')::jsonb AS r FROM ritc_records.object
)
INSERT INTO ritc_checkpoint.replay_clock(scope_digest,original_capture)
SELECT scope,min(least((r#>>'{event,payload,data,attestation,checkedAt}')::timestamptz,
                         (r#>>'{event,payload,data,acceptedAt}')::timestamptz))
FROM objects WHERE r#>>'{event,payload,kind}'='acceptance' AND r->>'kind'='intent' GROUP BY scope;

-- Refuse fresh admission before it can leave an uncertainty claim or reserve a
-- slot. A retry for an existing intent and completion of in-flight work stay usable.
CREATE FUNCTION ritc_checkpoint.guard_rotation_deadline() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF TG_RELID<>'ritc_checkpoint.origin'::regclass THEN RAISE EXCEPTION 'invalid trigger source'; END IF;
 IF NEW.claim#>>'{claim,transition}'='intent' AND OLD.claim IS NULL
    AND EXISTS(SELECT FROM ritc_checkpoint.replay_clock c WHERE c.scope_digest=OLD.scope_digest
       AND c.original_capture+interval '720 hours'<=clock_timestamp())
    AND NOT EXISTS(SELECT FROM ritc_checkpoint.admission a WHERE a.lineage=OLD.lineage
       AND a.event_id=(NEW.claim#>>'{claim,eventId}')::uuid AND a.transition='intent') THEN
  RAISE EXCEPTION 'rotate generation before admitting new erasure';
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ritc_checkpoint.guard_rotation_deadline() FROM PUBLIC,ritc_record_runtime,ritc_checkpoint_runtime;
CREATE TRIGGER guard_rotation_deadline BEFORE UPDATE OF claim ON ritc_checkpoint.origin
FOR EACH ROW EXECUTE FUNCTION ritc_checkpoint.guard_rotation_deadline();

-- A record writer validates its ticket and then inserts on a separate connection.
-- Serialize the final insert with sealing so a paused writer cannot repopulate a retired scope.
CREATE FUNCTION ritc_checkpoint.require_open_object_scope() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE scope text=split_part(NEW.object_key,'/',1); record jsonb; captured timestamptz; original timestamptz; mode text;
BEGIN
 IF TG_RELID<>'ritc_records.object'::regclass THEN RAISE EXCEPTION 'invalid trigger source'; END IF;
 SELECT head->>'mode' INTO mode FROM ritc_checkpoint.origin WHERE scope_digest=scope
   AND (head->>'mode' IN ('active','pending','blocked') OR (head->>'mode'='recovery' AND session_user=
        pg_get_userbyid((SELECT relowner FROM pg_class WHERE oid='ritc_checkpoint.origin'::regclass)))) FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'journal object scope is absent or fenced'; END IF;
 IF EXISTS(SELECT FROM ritc_checkpoint.replay_clock WHERE scope_digest=scope
   AND original_capture+interval '2160 hours'<=clock_timestamp()) THEN RAISE EXCEPTION 'overdue generation is quarantined'; END IF;
 record=convert_from(NEW.content,'UTF8')::jsonb;
 IF record->>'kind'='intent' AND record#>>'{event,payload,kind}'='acceptance' THEN
  IF record#>>'{event,payload,data,attestation,checkedAt}' IS NULL OR record#>>'{event,payload,data,acceptedAt}' IS NULL THEN
   RAISE EXCEPTION 'original replay clock required';
  END IF;
  captured=least((record#>>'{event,payload,data,attestation,checkedAt}')::timestamptz,
                 (record#>>'{event,payload,data,acceptedAt}')::timestamptz);
  IF captured>clock_timestamp() THEN RAISE EXCEPTION 'future original capture'; END IF;
  INSERT INTO ritc_checkpoint.replay_clock VALUES(scope,captured)
   ON CONFLICT(scope_digest) DO UPDATE SET original_capture=least(ritc_checkpoint.replay_clock.original_capture,EXCLUDED.original_capture)
   RETURNING original_capture INTO original;
  IF mode<>'recovery' AND clock_timestamp()>=original+interval '720 hours' AND NOT EXISTS(
   SELECT FROM ritc_records.object WHERE object_key=NEW.object_key AND record_hash=NEW.record_hash AND content=NEW.content
  ) THEN RAISE EXCEPTION 'rotate generation before admitting new erasure'; END IF;
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ritc_checkpoint.require_open_object_scope() FROM PUBLIC,ritc_checkpoint_runtime,ritc_record_runtime;
CREATE TRIGGER require_open_object_scope BEFORE INSERT ON ritc_records.object
FOR EACH ROW EXECUTE FUNCTION ritc_checkpoint.require_open_object_scope();
CREATE INDEX object_scope ON ritc_records.object ((split_part(object_key,'/',1)));

ALTER TABLE ritc_checkpoint.recovery_seal ADD COLUMN details_retired_at timestamptz;

CREATE FUNCTION ritc_checkpoint.retire_details(generation uuid, scope text, seal_digest text)
RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog AS $$
DECLARE retired timestamptz;
BEGIN
 IF current_user<>session_user OR session_user<>pg_get_userbyid((SELECT relowner FROM pg_class
     WHERE oid='ritc_checkpoint.origin'::regclass)) OR pg_is_in_recovery() THEN
  RAISE EXCEPTION 'retirement requires authority owner';
 END IF;
 PERFORM FROM ritc_checkpoint.origin WHERE lineage=generation AND scope_digest=scope AND head->>'mode'='sealed'
   AND head->'head'->>'fenced'='true' AND claim IS NULL AND pending IS NULL FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'cannot retire an unsealed authority'; END IF;
 SELECT r.details_retired_at INTO STRICT retired FROM ritc_checkpoint.recovery_seal r
 JOIN ritc_checkpoint.successor s ON s.predecessor=r.lineage WHERE r.lineage=generation
   AND s.proof->>'predecessorSealDigest'=seal_digest AND s.proof->>'predecessorScopeDigest'=scope
   AND r.proof->>'scopeDigest'=scope;
 DELETE FROM ritc_records.object WHERE split_part(object_key,'/',1)=scope;
 DELETE FROM ritc_checkpoint.worker_allowance WHERE lineage=generation;
 DELETE FROM ritc_checkpoint.admission WHERE lineage=generation;
 UPDATE ritc_checkpoint.recovery_seal SET tail_objects='[]', details_retired_at=clock_timestamp()
   WHERE lineage=generation AND details_retired_at IS NULL;
 RETURN retired IS NULL;
END $$;
REVOKE ALL ON FUNCTION ritc_checkpoint.retire_details(uuid,text,text) FROM PUBLIC,ritc_record_runtime,ritc_checkpoint_runtime;
COMMIT;
