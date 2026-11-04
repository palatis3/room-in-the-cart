-- One immutable, owner-staged archive window per quarantine database.
CREATE TABLE ritc.privacy_restore_window (
 singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
 window_id uuid UNIQUE NOT NULL,
 destination_oid oid NOT NULL,
 source_identity text NOT NULL,
 source_database_oid oid NOT NULL,
 manifest_digest text NOT NULL CHECK(manifest_digest ~ '^[0-9a-f]{64}$'),
 segment_count integer NOT NULL CHECK(segment_count>0),
 CHECK(destination_oid<>source_database_oid)
);
CREATE TABLE ritc.privacy_restore_window_segment (
 window_id uuid NOT NULL REFERENCES ritc.privacy_restore_window(window_id),
 position integer NOT NULL CHECK(position>0),
 run_id uuid UNIQUE NOT NULL,
 bundle_digest text NOT NULL CHECK(bundle_digest ~ '^[0-9a-f]{64}$'),
 head jsonb NOT NULL,
 jobs integer NOT NULL CHECK(jobs BETWEEN 0 AND 10000),
 PRIMARY KEY(window_id,position)
);
DO $$ DECLARE t text; BEGIN FOREACH t IN ARRAY ARRAY['privacy_restore_window','privacy_restore_window_segment'] LOOP
 EXECUTE format('ALTER TABLE ritc.%I ENABLE ROW LEVEL SECURITY',t);
 EXECUTE format('ALTER TABLE ritc.%I FORCE ROW LEVEL SECURITY',t);
 EXECUTE format('CREATE POLICY owner_scope ON ritc.%I TO %I USING(true) WITH CHECK(true)',t,current_user);
 EXECUTE format('REVOKE ALL ON ritc.%I FROM PUBLIC,ritc_app,ritc_worker',t);
 EXECUTE format('CREATE TRIGGER immutable_restore_window BEFORE UPDATE OR DELETE ON ritc.%I FOR EACH ROW EXECUTE FUNCTION ritc.privacy_journal_immutable()',t);
END LOOP; END $$;

CREATE OR REPLACE FUNCTION ritc.privacy_restore_register(r uuid,destination oid,bundle text,head jsonb,events jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE window_row ritc.privacy_restore_window;segment ritc.privacy_restore_window_segment;
 origin ritc.privacy_journal_origin;event jsonb;p jsonb;t jsonb;e jsonb;current_rows jsonb;current_row jsonb;hs uuid[];j uuid;h uuid;m uuid;existing ritc.member;acceptance_id uuid;target_d text;observations jsonb;
BEGIN
 IF destination IS DISTINCT FROM (SELECT oid FROM pg_database WHERE datname=current_database()) THEN RAISE EXCEPTION 'destination_oid_conflict'; END IF;
 SELECT * INTO STRICT origin FROM ritc.privacy_journal_origin WHERE singleton FOR UPDATE;
 SELECT * INTO window_row FROM ritc.privacy_restore_window WHERE singleton;
 IF FOUND THEN
  SELECT * INTO segment FROM ritc.privacy_restore_window_segment s WHERE s.window_id=window_row.window_id AND s.run_id=r;
  IF NOT FOUND OR window_row.destination_oid<>destination OR segment.bundle_digest IS DISTINCT FROM bundle
   OR segment.head IS DISTINCT FROM head OR segment.position>window_row.segment_count
   OR NOT EXISTS(SELECT 1 FROM ritc.privacy_journal_source_registration s
    WHERE singleton AND s.database_oid=window_row.source_database_oid AND s.source_identity=window_row.source_identity)
  THEN RAISE EXCEPTION 'restore_window_segment_conflict'; END IF;
  IF segment.position>1 AND (NOT origin.fenced OR (
   SELECT count(*) FROM ritc.privacy_restore_window_segment s JOIN ritc.privacy_restore_run v ON v.run_id=s.run_id
   WHERE s.window_id=window_row.window_id AND s.position<segment.position AND v.phase='local_app_erased'
    AND v.destination_oid=destination AND v.bundle_digest=s.bundle_digest AND v.head=s.head
  )<>segment.position-1) THEN RAISE EXCEPTION 'restore_window_predecessor_pending'; END IF;
 END IF;
 IF head->>'fenced' IS DISTINCT FROM 'true' OR ((segment.position IS NULL OR segment.position=1) AND (
  head->>'lineage' IS DISTINCT FROM origin.lineage::text OR head->>'schemaDigest' IS DISTINCT FROM origin.schema_digest
  OR head->>'configurationId' IS DISTINCT FROM origin.configuration_id
 )) THEN RAISE EXCEPTION 'journal_origin_conflict'; END IF;
 IF jsonb_typeof(events) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'journal_restore_events_invalid'; END IF;
 IF jsonb_array_length(events)>10000 OR octet_length(events::text)>67108864 THEN RAISE EXCEPTION 'journal_too_large'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(events) x(value) WHERE octet_length((value->'payload')::text)>1048576) THEN
  RAISE EXCEPTION 'journal_source_event_too_large';
 END IF;
 IF segment.position IS NOT NULL AND (SELECT count(*) FROM jsonb_array_elements(events) e(value)
  WHERE value->'payload'->>'kind'='acceptance')<>segment.jobs THEN RAISE EXCEPTION 'restore_window_job_count_conflict'; END IF;
 IF EXISTS(SELECT 1 FROM ritc.privacy_restore_run WHERE run_id=r) THEN
  IF EXISTS(SELECT 1 FROM ritc.privacy_restore_run WHERE run_id=r AND destination_oid=destination AND bundle_digest=bundle AND privacy_restore_run.head=privacy_restore_register.head) THEN RETURN r; END IF;
  RAISE EXCEPTION 'restore_run_conflict';
 END IF;
 -- Validate the complete plan before applying its first effect.
 FOR event IN SELECT value FROM jsonb_array_elements(events) WHERE value->'payload'->>'kind'='acceptance' LOOP
  p=event->'payload'->'data';j=(event->'payload'->>'jobId')::uuid;acceptance_id=(event->>'eventId')::uuid;
  IF (event->'payload'->>'lineage') IS DISTINCT FROM (head->>'lineage') OR (event->'payload'->>'schemaDigest') IS DISTINCT FROM (head->>'schemaDigest') OR (event->'payload'->>'configurationId') IS DISTINCT FROM (head->>'configurationId') OR event->>'payloadDigest'<>encode(sha256(convert_to(ritc.privacy_journal_canonical(event->'payload'),'utf8')),'hex') THEN RAISE EXCEPTION 'journal_event_conflict'; END IF;
  IF EXISTS(SELECT 1 FROM ritc.privacy_job WHERE job_id=j OR identity_hash=p->>'identityHash') OR EXISTS(SELECT 1 FROM ritc.identity_erasure WHERE identity_hash=p->>'identityHash') THEN RAISE EXCEPTION 'restore_job_conflict'; END IF;
  SELECT array_agg(DISTINCT (x->>'householdId')::uuid ORDER BY (x->>'householdId')::uuid) INTO hs FROM jsonb_array_elements(p->'targets') x;
  PERFORM 1 FROM ritc.household WHERE household_id=ANY(hs) ORDER BY household_id FOR UPDATE;
  current_rows=ritc.privacy_journal_snapshot(hs);
  FOR e IN SELECT value FROM jsonb_array_elements(COALESCE(p->'guardianPreimage','[]')) LOOP
   h=split_part(e->>'key','/',1)::uuid;IF NOT EXISTS(SELECT 1 FROM ritc.household WHERE household_id=h) THEN CONTINUE;END IF;
   SELECT value->'value' INTO current_row FROM jsonb_array_elements(current_rows) WHERE value->>'table'=e->>'table' AND value->>'key'=e->>'key';
   IF current_row IS DISTINCT FROM e->'value' THEN RAISE EXCEPTION 'restore_guardian_preimage_conflict';END IF;
  END LOOP;
  FOR t IN SELECT value FROM jsonb_array_elements(p->'targets') LOOP
   h=(t->>'householdId')::uuid;m=(t->>'memberId')::uuid;
   SELECT * INTO existing FROM ritc.member WHERE household_id=h AND member_id=m;
   IF NOT FOUND THEN CONTINUE; END IF;
   SELECT value->'value' INTO current_row FROM jsonb_array_elements(current_rows) WHERE value->>'table'='member' AND value->>'key'=h::text||'/'||m::text;
   IF t->>'kind'='explicit_sole_guardian_profile' AND t->>'principalKnown'='true' AND NOT EXISTS(SELECT 1 FROM ritc.guardian_child_principal WHERE identity_hash=t->'binding'->>'identity_hash') THEN RAISE EXCEPTION 'restore_guardian_principal_conflict';END IF;
   IF current_row IS DISTINCT FROM t->'binding' OR (t->>'kind'='self_adult' AND (existing.kind<>'adult' OR current_row->>'identity_hash'<>p->>'identityHash')) OR (t->>'kind'='explicit_sole_guardian_profile' AND existing.kind<>'child') THEN RAISE EXCEPTION 'restore_target_binding_conflict'; END IF;
  END LOOP;
  FOR e IN SELECT value FROM jsonb_array_elements(p->'effects') LOOP
   -- A household absent from B is recorded with no effect. A partially absent
   -- target with a still-present effect is unsupported, never recomputed.
   h=split_part(e->>'key','/',1)::uuid;
   IF NOT EXISTS(SELECT 1 FROM ritc.household WHERE household_id=h) THEN CONTINUE; END IF;
   SELECT value->'value' INTO current_row FROM jsonb_array_elements(current_rows) WHERE value->>'table'=e->>'table' AND value->>'key'=e->>'key';
   IF COALESCE(current_row,'null'::jsonb) IS DISTINCT FROM e->'before' THEN RAISE EXCEPTION 'restore_preimage_conflict'; END IF;
  END LOOP;
 END LOOP;
 INSERT INTO ritc.privacy_restore_run(run_id,destination_oid,bundle_digest,head) VALUES(r,destination,bundle,head);
 UPDATE ritc.privacy_journal_origin SET fenced=true WHERE singleton;
 -- Group observations once while preserving the canonical journal order.
 FOR event,observations IN
  WITH expanded AS MATERIALIZED (
   SELECT value,ord,value->'payload'->>'jobId' AS job_key,value->'payload'->>'kind' AS event_kind
   FROM jsonb_array_elements(events) WITH ORDINALITY AS e(value,ord)
  ), grouped_observations AS (
   SELECT job_key,jsonb_agg(value->'payload' ORDER BY ord) AS payloads FROM expanded
   WHERE event_kind<>'acceptance' GROUP BY job_key
  )
  SELECT expanded.value,COALESCE(grouped_observations.payloads,'[]'::jsonb)
  FROM expanded LEFT JOIN grouped_observations USING(job_key)
  WHERE expanded.event_kind='acceptance' ORDER BY expanded.ord
 LOOP
  p=event->'payload'->'data';j=(event->'payload'->>'jobId')::uuid;acceptance_id=(event->>'eventId')::uuid;
  INSERT INTO ritc.privacy_job(job_id,identity_hash,issuer,subject,receipt_hash,payload_digest,created_at,receipt_retention_days,marker_retention_days,receipt_until,marker_until) VALUES(j,p->>'identityHash',NULL,NULL,p->>'receiptHash',p->>'requestDigest',(p->>'acceptedAt')::timestamptz,(p->>'receiptDays')::integer,(p->>'markerDays')::integer,(p->>'receiptUntil')::timestamptz,(p->>'markerUntil')::timestamptz);
  INSERT INTO ritc.identity_erasure VALUES(p->>'identityHash',j,(p->>'markerUntil')::timestamptz);
  INSERT INTO ritc.privacy_restore_job(job_id,run_id,event_id,acceptance_digest,identity_hash,source_observations) VALUES(j,r,acceptance_id,event->>'payloadDigest',p->>'identityHash',observations);
  FOR t IN SELECT value FROM jsonb_array_elements(p->'targets') LOOP
   h=(t->>'householdId')::uuid;m=(t->>'memberId')::uuid;target_d=encode(sha256(convert_to(ritc.privacy_journal_canonical(t),'utf8')),'hex');
   INSERT INTO ritc.privacy_restore_target VALUES(r,j,acceptance_id,h,m,target_d,t,EXISTS(SELECT 1 FROM ritc.member WHERE household_id=h AND member_id=m));
   IF EXISTS(SELECT 1 FROM ritc.member WHERE household_id=h AND member_id=m) THEN INSERT INTO ritc.privacy_target(job_id,household_id,member_id) VALUES(j,h,m);
   ELSE INSERT INTO ritc.privacy_restore_receipt(event_id,household_id,member_id,target_digest,result) VALUES(acceptance_id,h,m,target_d,'absent_no_effect'); END IF;
  END LOOP;
  INSERT INTO ritc.privacy_restore_effect_context(run_id,transaction_id,actor_oid,table_name,row_key,effect) SELECT r,pg_current_xact_id(),(SELECT oid FROM pg_roles WHERE rolname=session_user),value->>'table',value->>'key',value FROM jsonb_array_elements(p->'effects');
  FOR e IN SELECT value FROM jsonb_array_elements(p->'effects') LOOP
   IF EXISTS(SELECT 1 FROM ritc.household WHERE household_id=split_part(e->>'key','/',1)::uuid) THEN PERFORM ritc.privacy_journal_apply_effect(e); END IF;
  END LOOP;
  -- Hash matching clears restored credentials despite issuer/subject not being
  -- retained in replay jobs. No provider session deletion is performed.
  DELETE FROM ritc.browser_auth WHERE encode(sha256(convert_to(issuer||E'\n'||subject,'utf8')),'hex')=p->>'identityHash';
 END LOOP;
 INSERT INTO ritc.retired_purchase(original_hash)
 SELECT DISTINCT marker.value->>'originalHash'
 FROM jsonb_array_elements(events) AS event_row(value)
 CROSS JOIN LATERAL jsonb_array_elements(event_row.value->'payload'->'data'->'retiredPurchases') AS marker(value)
 WHERE event_row.value->'payload'->>'kind'='target_erased'
 ON CONFLICT DO NOTHING;
 IF NOT EXISTS(SELECT 1 FROM ritc.privacy_restore_target t WHERE run_id=r AND NOT EXISTS(SELECT 1 FROM ritc.privacy_restore_receipt q WHERE q.event_id=t.event_id AND q.household_id=t.household_id AND q.member_id=t.member_id AND q.target_digest=t.target_digest)) THEN UPDATE ritc.privacy_restore_run SET phase='local_app_erased' WHERE run_id=r; END IF;
 RETURN r;
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_restore_register(uuid,oid,text,jsonb,jsonb) FROM PUBLIC;
