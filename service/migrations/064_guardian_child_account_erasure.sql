-- The worker and restored database both erase the same child membership targets.
-- The subject-wide marker immediately stops session use and removes pending child sign-ins.
CREATE FUNCTION ritc.privacy_check_child_bindings(child_hash text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF EXISTS (
   SELECT 1 FROM ritc.member m
   WHERE encode(sha256(convert_to(m.issuer||E'\n'||m.subject,'utf8')),'hex')=child_hash
     AND (m.kind<>'child' OR m.organizer OR EXISTS (
       SELECT 1 FROM ritc.shop s WHERE s.household_id=m.household_id AND s.shopper_id=m.member_id AND s.phase<>'closed'))
 ) THEN RAISE EXCEPTION 'unavailable'; END IF;
 -- A historical enrollment with more than one provider subject cannot be
 -- removed as this child's data. Retain it for identity resolution.
 IF EXISTS (
   WITH bindings AS (
    SELECT household_id,invite_id,issuer,subject FROM ritc.guardian_child_claim
    UNION SELECT household_id,invite_id,issuer,subject FROM ritc.guardian_child_signin
   ), enrolled AS (
    SELECT i.household_id,i.enrollment_id,encode(sha256(convert_to(b.issuer||E'\n'||b.subject,'utf8')),'hex') AS identity_hash
    FROM bindings b JOIN ritc.guardian_child_invitation i USING(household_id,invite_id)
   ) SELECT 1 FROM enrolled GROUP BY household_id,enrollment_id
     HAVING bool_or(identity_hash=child_hash) AND bool_or(identity_hash<>child_hash)
 ) THEN RAISE EXCEPTION 'unavailable'; END IF;
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_check_child_bindings(text) FROM PUBLIC;

CREATE FUNCTION ritc.privacy_journal_child_request(
 i text, guardian text, session_id uuid, h uuid, enrollment uuid, review uuid, child_subject text,
 j uuid, receipt text, request_digest text, rd integer, md integer, attestation jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE
 child_hash text:=encode(sha256(convert_to(i||E'\n'||child_subject,'utf8')),'hex');
 guardian_hash text:=encode(sha256(convert_to(i||E'\n'||guardian,'utf8')),'hex');
 origin ritc.privacy_journal_origin;
 job ritc.privacy_job;
 targets jsonb;
 event jsonb;
BEGIN
 SELECT * INTO origin FROM ritc.privacy_journal_origin WHERE singleton FOR SHARE;
 IF NOT FOUND OR origin.fenced OR attestation->>'configurationId' IS DISTINCT FROM origin.configuration_id
    OR attestation->>'providerAvailability' IS DISTINCT FROM 'configured_adapter_passed'
    OR attestation->>'appleGate' IS DISTINCT FROM 'availability_contract_passed'
    OR NOT COALESCE(attestation->>'authenticatedMethod'=ANY(ARRAY['otp','password','oauth','sso/saml']),false)
    OR NOT COALESCE((attestation->>'authenticatedAt')::timestamptz BETWEEN clock_timestamp()-interval '5 minutes' AND clock_timestamp()+interval '5 seconds',false)
    OR attestation->>'sessionBindingHash' IS DISTINCT FROM encode(sha256(convert_to(i||E'\n'||guardian||E'\n'||session_id::text,'utf8')),'hex')
    OR rd NOT BETWEEN 1 AND 365 OR md NOT BETWEEN rd AND 3650
    OR (attestation->'policy'->>'receiptRetentionDays')::integer IS DISTINCT FROM rd
    OR (attestation->'policy'->>'erasureMarkerRetentionDays')::integer IS DISTINCT FROM md
    OR NOT COALESCE((attestation->'policy'->>'verifiedBackupRetentionDays')::integer BETWEEN 0 AND md,false)
    OR receipt !~ '^[a-f0-9]{64}$' OR request_digest !~ '^[a-f0-9]{64}$'
 THEN RAISE EXCEPTION 'journal_unavailable'; END IF;
 IF guardian=child_subject OR child_subject IS NULL THEN RAISE EXCEPTION 'unavailable'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(child_hash,0));
 PERFORM 1 FROM ritc.household hh WHERE hh.household_id=h OR hh.household_id IN (
  SELECT m.household_id FROM ritc.member m WHERE m.issuer=i AND m.subject=child_subject
  UNION SELECT c.household_id FROM ritc.guardian_child_claim c WHERE c.issuer=i AND c.subject=child_subject
  UNION SELECT a.household_id FROM ritc.guardian_child_signin a WHERE a.issuer=i AND a.subject=child_subject
 ) ORDER BY hh.household_id FOR UPDATE;
 IF ritc.guardian_assert_deletion_review(i,guardian,session_id,h,enrollment,review) IS DISTINCT FROM child_subject
    OR NOT ritc.provider_session_live(session_id,guardian::uuid) OR ritc.identity_blocked(i,guardian)
 THEN RAISE EXCEPTION 'unavailable'; END IF;
 PERFORM ritc.privacy_check_child_bindings(child_hash);
 IF EXISTS(SELECT 1 FROM ritc.privacy_job WHERE job_id=j OR identity_hash=child_hash)
 THEN RAISE EXCEPTION 'key_reused'; END IF;
 IF ritc.identity_blocked(i,child_subject) THEN RAISE EXCEPTION 'unavailable'; END IF;
 INSERT INTO ritc.privacy_job(job_id,identity_hash,issuer,subject,receipt_hash,payload_digest,
  receipt_retention_days,marker_retention_days,receipt_until,marker_until)
 VALUES(j,child_hash,i,child_subject,receipt,request_digest,rd,md,
  clock_timestamp()+make_interval(days=>rd),clock_timestamp()+make_interval(days=>md)) RETURNING * INTO job;
 INSERT INTO ritc.privacy_target(job_id,household_id,member_id)
 SELECT j,m.household_id,m.member_id FROM ritc.member m WHERE m.issuer=i AND m.subject=child_subject AND m.erased_at IS NULL;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
  'householdId',m.household_id,'memberId',m.member_id,'kind','guardian_child_account',
  'binding',jsonb_build_object('household_id',m.household_id,'member_id',m.member_id,'kind',m.kind,
   'state',m.state,'organizer',m.organizer,'can_contribute',m.can_contribute,'erased_at',m.erased_at,'identity_hash',child_hash)
 ) ORDER BY m.household_id,m.member_id),'[]') INTO targets FROM ritc.member m JOIN ritc.privacy_target t USING(household_id,member_id) WHERE t.job_id=j;
 IF jsonb_array_length(targets)>1000 THEN RAISE EXCEPTION 'journal_too_large'; END IF;
 INSERT INTO ritc.identity_erasure(identity_hash,job_id,retain_until) VALUES(child_hash,j,job.marker_until);
 event=ritc.privacy_journal_emit(j,'acceptance',jsonb_build_object(
  'identityHash',child_hash,'receiptHash',receipt,'requestDigest',request_digest,'acceptedAt',job.created_at,
  'receiptDays',rd,'markerDays',md,'receiptUntil',job.receipt_until,'markerUntil',job.marker_until,
  'attestation',attestation||jsonb_build_object('guardianAuthorization',jsonb_build_object(
    'guardianHash',guardian_hash,'householdId',h,'enrollmentId',enrollment,'reviewHash',encode(sha256(convert_to(review::text,'utf8')),'hex'))),
  'targets',targets,'effects','[]'::jsonb));
 INSERT INTO ritc.privacy_journal_target(event_id,household_id,member_id,target_digest,target)
 SELECT (event->>'eventId')::uuid,(t->>'householdId')::uuid,(t->>'memberId')::uuid,
  encode(sha256(convert_to(ritc.privacy_journal_canonical(t),'utf8')),'hex'),t FROM jsonb_array_elements(targets) t;
 RETURN event;
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_journal_child_request(text,text,uuid,uuid,uuid,uuid,text,uuid,text,text,integer,integer,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.privacy_journal_child_request(text,text,uuid,uuid,uuid,uuid,text,uuid,text,text,integer,integer,jsonb) TO ritc_app;

-- A classified child with no active membership must also use guardian review.
ALTER FUNCTION ritc.privacy_journal_request(text,text,uuid,uuid,text,text,jsonb,integer,integer,jsonb) RENAME TO privacy_journal_adult_request_v022;
REVOKE ALL ON FUNCTION ritc.privacy_journal_adult_request_v022(text,text,uuid,uuid,text,text,jsonb,integer,integer,jsonb) FROM ritc_app;
CREATE FUNCTION ritc.privacy_journal_request(i text,s text,p uuid,j uuid,r text,d text,choices jsonb,rd integer,md integer,attestation jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended(encode(sha256(convert_to(i||E'\n'||s,'utf8')),'hex'),0));
 IF ritc.identity_has_child_profile(i,s) THEN RAISE EXCEPTION 'adult_scope_required'; END IF;
 RETURN ritc.privacy_journal_adult_request_v022(i,s,p,j,r,d,choices,rd,md,attestation);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_journal_request(text,text,uuid,uuid,text,text,jsonb,integer,integer,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.privacy_journal_request(text,text,uuid,uuid,text,text,jsonb,integer,integer,jsonb) TO ritc_app;

CREATE FUNCTION ritc.privacy_validate_child_restore(events jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE data jsonb; child_hash text;
BEGIN
 FOR data IN SELECT x->'payload'->'data' FROM jsonb_array_elements(events) x
  WHERE x->'payload'->>'kind'='acceptance' LOOP
  IF NOT (data->'attestation' ? 'guardianAuthorization') THEN
   IF EXISTS(SELECT 1 FROM jsonb_array_elements(data->'targets') t WHERE t->>'kind'='guardian_child_account')
    THEN RAISE EXCEPTION 'restore_target_binding_conflict'; END IF;
   CONTINUE;
  END IF;
  child_hash=data->>'identityHash';
  IF data->'attestation' ? 'sqlAdultScopeCheck' OR data->'attestation'->'guardianAuthorization'->>'guardianHash'=child_hash
     OR data->'effects' IS DISTINCT FROM '[]'::jsonb OR COALESCE(data->'guardianPreimage','[]')<>'[]'::jsonb
     OR EXISTS(SELECT 1 FROM jsonb_array_elements(data->'targets') t
      WHERE t->>'kind' IS DISTINCT FROM 'guardian_child_account' OR t->'binding'->>'kind' IS DISTINCT FROM 'child'
       OR t->'binding'->>'identity_hash' IS DISTINCT FROM child_hash)
  THEN RAISE EXCEPTION 'restore_target_binding_conflict'; END IF;
  PERFORM ritc.privacy_check_child_bindings(child_hash);
  IF EXISTS(SELECT 1 FROM ritc.member m WHERE encode(sha256(convert_to(m.issuer||E'\n'||m.subject,'utf8')),'hex')=child_hash
    AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(data->'targets') t WHERE t->>'householdId'=m.household_id::text AND t->>'memberId'=m.member_id::text))
  THEN RAISE EXCEPTION 'restore_target_binding_conflict'; END IF;
 END LOOP;
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_validate_child_restore(jsonb) FROM PUBLIC;

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
 PERFORM ritc.privacy_validate_child_restore(events);
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
