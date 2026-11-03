-- Local restore journal. No provider/policy/lineage/key is enabled by migration.
-- Trusted owner verifies signatures externally; SQL enforces persisted exact scope.
CREATE FUNCTION ritc.privacy_journal_canonical(v jsonb) RETURNS text LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $$
 SELECT CASE jsonb_typeof(v) WHEN 'object' THEN '{'||COALESCE((SELECT string_agg(to_jsonb(key)::text||':'||ritc.privacy_journal_canonical(value),',' ORDER BY key COLLATE "C") FROM jsonb_each(v)),'')||'}'
 WHEN 'array' THEN '['||COALESCE((SELECT string_agg(ritc.privacy_journal_canonical(value),',' ORDER BY ord) FROM jsonb_array_elements(v) WITH ORDINALITY x(value,ord)),'')||']' ELSE v::text END
$$;
REVOKE ALL ON FUNCTION ritc.privacy_journal_canonical(jsonb) FROM PUBLIC;
CREATE TABLE ritc.privacy_journal_origin(singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),lineage uuid NOT NULL UNIQUE,schema_digest text NOT NULL CHECK(schema_digest ~ '^[0-9a-f]{64}$'),configuration_id text NOT NULL CHECK(length(configuration_id) BETWEEN 1 AND 100),registered_at timestamptz NOT NULL DEFAULT clock_timestamp(),fenced boolean NOT NULL DEFAULT false);
CREATE TABLE ritc.privacy_journal_outbox(event_id uuid PRIMARY KEY,lineage uuid NOT NULL,job_id uuid NOT NULL,kind text NOT NULL CHECK(kind IN('acceptance','target_erased','source_completed','source_pending')),payload jsonb NOT NULL,payload_digest text NOT NULL CHECK(payload_digest ~ '^[0-9a-f]{64}$'),created_at timestamptz NOT NULL DEFAULT clock_timestamp());
CREATE INDEX privacy_journal_job ON ritc.privacy_journal_outbox(job_id,created_at,event_id);
CREATE UNIQUE INDEX privacy_journal_acceptance ON ritc.privacy_journal_outbox(job_id) WHERE kind='acceptance';
CREATE TABLE ritc.privacy_journal_target(event_id uuid NOT NULL REFERENCES ritc.privacy_journal_outbox,household_id uuid NOT NULL,member_id uuid NOT NULL,target_digest text NOT NULL,target jsonb NOT NULL,PRIMARY KEY(event_id,household_id,member_id));
CREATE TABLE ritc.privacy_journal_ack(event_id uuid PRIMARY KEY REFERENCES ritc.privacy_journal_outbox,payload_digest text NOT NULL,head_seq bigint NOT NULL CHECK(head_seq>0),head_hash text NOT NULL CHECK(head_hash ~ '^[0-9a-f]{64}$'),acknowledged_at timestamptz NOT NULL DEFAULT clock_timestamp());
CREATE TABLE ritc.privacy_restore_run(run_id uuid PRIMARY KEY,destination_oid oid NOT NULL,bundle_digest text NOT NULL CHECK(bundle_digest ~ '^[0-9a-f]{64}$'),head jsonb NOT NULL,phase text NOT NULL DEFAULT 'quarantined' CHECK(phase IN('quarantined','local_app_erased')),created_at timestamptz NOT NULL DEFAULT clock_timestamp());
CREATE TABLE ritc.privacy_restore_job(job_id uuid PRIMARY KEY REFERENCES ritc.privacy_job,run_id uuid NOT NULL REFERENCES ritc.privacy_restore_run,event_id uuid NOT NULL UNIQUE,acceptance_digest text NOT NULL,identity_hash text NOT NULL,source_observations jsonb NOT NULL DEFAULT '[]');
CREATE TABLE ritc.privacy_restore_target(run_id uuid NOT NULL REFERENCES ritc.privacy_restore_run,job_id uuid NOT NULL REFERENCES ritc.privacy_restore_job,event_id uuid NOT NULL,household_id uuid NOT NULL,member_id uuid NOT NULL,target_digest text NOT NULL,target jsonb NOT NULL,present boolean NOT NULL,PRIMARY KEY(run_id,event_id,household_id,member_id));
CREATE TABLE ritc.privacy_restore_effect_context(run_id uuid NOT NULL REFERENCES ritc.privacy_restore_run,transaction_id xid8 NOT NULL,actor_oid oid NOT NULL,table_name text NOT NULL CHECK(table_name IN('household','member','shop','shop_authority','device','replay_window','web_session','view_grant','invite','consent','guardian_relationship','billing_seat','guardian_enrollment','guardian_attempt','guardian_provider_event','guardian_child_invitation','guardian_child_claim','guardian_child_signin','guardian_native_challenge','guardian_intent','browser_auth')),row_key text NOT NULL,effect jsonb NOT NULL,PRIMARY KEY(run_id,table_name,row_key));
CREATE TABLE ritc.privacy_restore_receipt(event_id uuid NOT NULL,household_id uuid NOT NULL,member_id uuid NOT NULL,target_digest text NOT NULL,result text NOT NULL CHECK(result IN('erased','absent_no_effect')),applied_at timestamptz NOT NULL DEFAULT clock_timestamp(),PRIMARY KEY(event_id,household_id,member_id));
DO $$ DECLARE t text; BEGIN FOREACH t IN ARRAY ARRAY['privacy_journal_origin','privacy_journal_outbox','privacy_journal_target','privacy_journal_ack','privacy_restore_run','privacy_restore_job','privacy_restore_target','privacy_restore_receipt','privacy_restore_effect_context'] LOOP
 EXECUTE format('ALTER TABLE ritc.%I ENABLE ROW LEVEL SECURITY',t); EXECUTE format('ALTER TABLE ritc.%I FORCE ROW LEVEL SECURITY',t); EXECUTE format('REVOKE ALL ON ritc.%I FROM PUBLIC,ritc_app,ritc_worker',t);
END LOOP; END $$;
CREATE FUNCTION ritc.privacy_journal_immutable() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$ BEGIN RAISE EXCEPTION 'immutable journal'; END $$;
REVOKE ALL ON FUNCTION ritc.privacy_journal_immutable() FROM PUBLIC;
CREATE FUNCTION ritc.privacy_journal_origin_guard() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$ BEGIN IF TG_OP='UPDATE' AND (to_jsonb(NEW)-'fenced')=(to_jsonb(OLD)-'fenced') AND (NOT OLD.fenced OR NEW.fenced) THEN RETURN NEW; END IF;RAISE EXCEPTION 'immutable journal origin';END $$;
REVOKE ALL ON FUNCTION ritc.privacy_journal_origin_guard() FROM PUBLIC;
CREATE TRIGGER immutable_journal_origin BEFORE UPDATE OR DELETE ON ritc.privacy_journal_origin FOR EACH ROW EXECUTE FUNCTION ritc.privacy_journal_origin_guard();
CREATE TRIGGER immutable_journal BEFORE UPDATE OR DELETE ON ritc.privacy_journal_outbox FOR EACH ROW EXECUTE FUNCTION ritc.privacy_journal_immutable();
CREATE TRIGGER immutable_journal_target BEFORE UPDATE OR DELETE ON ritc.privacy_journal_target FOR EACH ROW EXECUTE FUNCTION ritc.privacy_journal_immutable();
CREATE TRIGGER immutable_restore_context BEFORE UPDATE OR DELETE ON ritc.privacy_restore_effect_context FOR EACH ROW EXECUTE FUNCTION ritc.privacy_journal_immutable();
CREATE TRIGGER immutable_restore_receipt BEFORE UPDATE OR DELETE ON ritc.privacy_restore_receipt FOR EACH ROW EXECUTE FUNCTION ritc.privacy_journal_immutable();

CREATE FUNCTION ritc.privacy_journal_snapshot(hs uuid[]) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT COALESCE(jsonb_agg(row ORDER BY row->>'table',row->>'key'),'[]') FROM (
 SELECT jsonb_build_object('table','household','key',row_key,'value',to_jsonb(v)-'row_key') AS row FROM (SELECT household_id::text AS row_key,household_id,archived_at FROM ritc.household WHERE household_id=ANY(hs)) v
 UNION ALL
 SELECT jsonb_build_object('table','member','key',row_key,'value',to_jsonb(v)-'row_key') AS row FROM (SELECT household_id::text||'/'||member_id::text AS row_key,household_id,member_id,kind,state,organizer,can_contribute,erased_at,encode(sha256(convert_to(issuer||E'\n'||subject,'utf8')),'hex') AS identity_hash FROM ritc.member WHERE household_id=ANY(hs)) v
 UNION ALL
 SELECT jsonb_build_object('table','shop','key',row_key,'value',to_jsonb(v)-'row_key') AS row FROM (SELECT household_id::text||'/'||shop_id::text AS row_key,household_id,shop_id,shopper_id,phase,revision,authority_epoch,measurement_closed_at FROM ritc.shop WHERE household_id=ANY(hs)) v
 UNION ALL
 SELECT jsonb_build_object('table','shop_authority','key',row_key,'value',to_jsonb(v)-'row_key') AS row FROM (SELECT household_id::text||'/'||shop_id::text||'/'||epoch::text AS row_key,household_id,shop_id,epoch,member_id,granted_at FROM ritc.shop_authority WHERE household_id=ANY(hs)) v
 UNION ALL
 SELECT jsonb_build_object('table','device','key',row_key,'value',to_jsonb(v)-'row_key') AS row FROM (SELECT household_id::text||'/'||device_id::text AS row_key,household_id,device_id,member_id,revoked_at,guardian_consent_id FROM ritc.device WHERE household_id=ANY(hs)) v
 UNION ALL
 SELECT jsonb_build_object('table','replay_window','key',row_key,'value',to_jsonb(v)-'row_key') AS row FROM (SELECT household_id::text||'/'||window_id::text AS row_key,household_id,window_id,member_id,revoked_at FROM ritc.replay_window WHERE household_id=ANY(hs)) v
 UNION ALL
 SELECT jsonb_build_object('table','web_session','key',row_key,'value',to_jsonb(v)-'row_key') AS row FROM (SELECT household_id::text||'/'||encode(sha256(convert_to(token_hash,'utf8')),'hex') AS row_key,household_id,member_id,encode(sha256(convert_to(token_hash,'utf8')),'hex') AS credential_hash,revoked_at FROM ritc.web_session WHERE household_id=ANY(hs)) v
 UNION ALL
 SELECT jsonb_build_object('table','view_grant','key',row_key,'value',to_jsonb(v)-'row_key') AS row FROM (SELECT household_id::text||'/'||grant_id::text AS row_key,household_id,grant_id,created_by,recipient_id,revoked_at FROM ritc.view_grant WHERE household_id=ANY(hs)) v
 UNION ALL
 SELECT jsonb_build_object('table','invite','key',row_key,'value',to_jsonb(v)-'row_key') AS row FROM (SELECT household_id::text||'/'||invite_id::text AS row_key,household_id,invite_id,created_by,redeemed_by,revoked_at FROM ritc.invite WHERE household_id=ANY(hs)) v
 UNION ALL
 SELECT jsonb_build_object('table','consent','key',row_key,'value',to_jsonb(v)-'row_key') AS row FROM (SELECT household_id::text||'/'||consent_id::text AS row_key,household_id,consent_id,child_id,guardian_id,granted_at,revoked_at,encode(sha256(convert_to(notice_version||E'\n'||verification_ref,'utf8')),'hex') AS evidence_hash FROM ritc.consent WHERE household_id=ANY(hs)) v
 UNION ALL
 SELECT jsonb_build_object('table','guardian_relationship','key',row_key,'value',to_jsonb(v)-'row_key') AS row FROM (SELECT household_id::text||'/'||child_id::text||'/'||guardian_id::text AS row_key,household_id,child_id,guardian_id,revoked_at,encode(sha256(convert_to(proof_ref,'utf8')),'hex') AS evidence_hash FROM ritc.guardian_relationship WHERE household_id=ANY(hs)) v
 UNION ALL
 SELECT jsonb_build_object('table','billing_seat','key',row_key,'value',to_jsonb(v)-'row_key') AS row FROM (SELECT household_id::text||'/'||slot::text AS row_key,household_id,slot,member_id FROM ritc.billing_seat WHERE household_id=ANY(hs)) v
 UNION ALL
 SELECT jsonb_build_object('table','guardian_enrollment','key',row_key,'value',to_jsonb(v)-'row_key') AS row FROM (SELECT household_id::text||'/'||enrollment_id::text AS row_key,household_id,enrollment_id,guardian_id,child_id,state,revision,encode(sha256(convert_to(ritc.privacy_journal_canonical(to_jsonb(g)-ARRAY['state','revision']),'utf8')),'hex') AS binding_hash FROM ritc.guardian_enrollment g WHERE household_id=ANY(hs)) v
 UNION ALL
 SELECT jsonb_build_object('table','guardian_attempt','key',row_key,'value',to_jsonb(v)-'row_key') AS row FROM (SELECT household_id::text||'/'||enrollment_id::text AS row_key,household_id,enrollment_id,attempt_id,encode(sha256(convert_to(ritc.privacy_journal_canonical(to_jsonb(g)),'utf8')),'hex') AS binding_hash FROM ritc.guardian_attempt g WHERE household_id=ANY(hs)) v
 UNION ALL
 SELECT jsonb_build_object('table','guardian_provider_event','key',row_key,'value',to_jsonb(v)-'row_key') AS row FROM (SELECT household_id::text||'/'||attempt_id::text AS row_key,household_id,attempt_id,encode(sha256(convert_to(ritc.privacy_journal_canonical(to_jsonb(g)),'utf8')),'hex') AS binding_hash FROM ritc.guardian_provider_event g WHERE household_id=ANY(hs)) v
 UNION ALL
 SELECT jsonb_build_object('table','guardian_child_invitation','key',row_key,'value',to_jsonb(v)-'row_key') AS row FROM (SELECT household_id::text||'/'||invite_id::text AS row_key,household_id,invite_id,enrollment_id,revoked_at,consumed_at,encode(sha256(convert_to(ritc.privacy_journal_canonical(to_jsonb(g)-ARRAY['revoked_at','consumed_at']),'utf8')),'hex') AS binding_hash FROM ritc.guardian_child_invitation g WHERE household_id=ANY(hs)) v
 UNION ALL
 SELECT jsonb_build_object('table','guardian_child_claim','key',row_key,'value',to_jsonb(v)-'row_key') AS row FROM (SELECT household_id::text||'/'||claim_id::text AS row_key,household_id,claim_id,invite_id,approved_at,finished_at,revoked_at,encode(sha256(convert_to(ritc.privacy_journal_canonical(to_jsonb(g)-ARRAY['approved_at','finished_at','revoked_at']),'utf8')),'hex') AS binding_hash FROM ritc.guardian_child_claim g WHERE household_id=ANY(hs)) v
 UNION ALL
 SELECT jsonb_build_object('table','guardian_child_signin','key',row_key,'value',to_jsonb(v)-'row_key') AS row FROM (SELECT household_id::text||'/'||invite_id::text||'/'||encode(sha256(convert_to(issuer||E'\n'||subject||E'\n'||session_id,'utf8')),'hex') AS row_key,household_id,invite_id,encode(sha256(convert_to(ritc.privacy_journal_canonical(to_jsonb(g)),'utf8')),'hex') AS binding_hash FROM ritc.guardian_child_signin g WHERE household_id=ANY(hs)) v
 UNION ALL
 SELECT jsonb_build_object('table','guardian_native_challenge','key',row_key,'value',to_jsonb(v)-'row_key') AS row FROM (SELECT household_id::text||'/'||challenge_id::text AS row_key,household_id,challenge_id,invite_id,encode(sha256(convert_to(ritc.privacy_journal_canonical(to_jsonb(g)),'utf8')),'hex') AS binding_hash FROM ritc.guardian_native_challenge g WHERE household_id=ANY(hs)) v
 UNION ALL
 SELECT jsonb_build_object('table','guardian_intent','key',row_key,'value',to_jsonb(v)-'row_key') AS row FROM (SELECT household_id::text||'/'||encode(sha256(convert_to(issuer||E'\n'||subject||E'\n'||client_key::text,'utf8')),'hex') AS row_key,household_id,enrollment_id,encode(sha256(convert_to(ritc.privacy_journal_canonical(to_jsonb(g)),'utf8')),'hex') AS binding_hash FROM ritc.guardian_intent g WHERE household_id=ANY(hs)) v
 UNION ALL
 SELECT jsonb_build_object('table','browser_auth','key',row_key,'value',to_jsonb(v)-'row_key') FROM (SELECT guardian_household_id::text||'/'||encode(sha256(convert_to(token_hash,'utf8')),'hex') AS row_key,guardian_household_id AS household_id,guardian_invite_id,phase,encode(sha256(convert_to(token_hash,'utf8')),'hex') AS credential_hash,revoked_at,email_cipher IS NOT NULL AS email_present,secret_cipher IS NOT NULL AS secret_present,encode(sha256(convert_to(ritc.privacy_journal_canonical(to_jsonb(b)-ARRAY['revoked_at','email_cipher','secret_cipher']),'utf8')),'hex') AS binding_hash FROM ritc.browser_auth b WHERE guardian_household_id=ANY(hs)) v
 ) all_rows
$$;
REVOKE ALL ON FUNCTION ritc.privacy_journal_snapshot(uuid[]) FROM PUBLIC;

-- Fixed table/column registry; there is no dynamic identifier supplied by an importer.
CREATE FUNCTION ritc.privacy_journal_apply_effect(effect jsonb) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE t text:=effect->>'table';k text:=effect->>'key';a jsonb:=effect->'after';expr text;cols text[];assignments text;c text;existing jsonb;
BEGIN
 SELECT value->'value' INTO existing FROM jsonb_array_elements(ritc.privacy_journal_snapshot(ARRAY[split_part(k,'/',1)::uuid])) WHERE value->>'table'=t AND value->>'key'=k;
 IF COALESCE(existing,'null'::jsonb) IS NOT DISTINCT FROM a THEN RETURN;END IF;
 IF COALESCE(existing,'null'::jsonb) IS DISTINCT FROM effect->'before' THEN RAISE EXCEPTION 'restore_effect_preimage_conflict';END IF;
 CASE t
 WHEN 'household' THEN expr='household_id::text';cols=ARRAY['archived_at']::text[];
 WHEN 'member' THEN expr='household_id::text||''/''||member_id::text';cols=ARRAY['state','organizer','can_contribute']::text[];
 WHEN 'shop' THEN expr='household_id::text||''/''||shop_id::text';cols=ARRAY['shopper_id','phase','revision','authority_epoch']::text[];
 WHEN 'shop_authority' THEN expr='household_id::text||''/''||shop_id::text||''/''||epoch::text';cols=ARRAY['household_id','shop_id','epoch','member_id','granted_at']::text[];
 WHEN 'device' THEN expr='household_id::text||''/''||device_id::text';cols=ARRAY['revoked_at']::text[];
 WHEN 'replay_window' THEN expr='household_id::text||''/''||window_id::text';cols=ARRAY['revoked_at']::text[];
 WHEN 'web_session' THEN expr='household_id::text||''/''||encode(sha256(convert_to(token_hash,''utf8'')),''hex'')';cols=ARRAY['revoked_at']::text[];
 WHEN 'view_grant' THEN expr='household_id::text||''/''||grant_id::text';cols=ARRAY['revoked_at']::text[];
 WHEN 'invite' THEN expr='household_id::text||''/''||invite_id::text';cols=ARRAY['revoked_at']::text[];
 WHEN 'consent' THEN expr='household_id::text||''/''||consent_id::text';cols=ARRAY['revoked_at']::text[];
 WHEN 'guardian_relationship' THEN expr='household_id::text||''/''||child_id::text||''/''||guardian_id::text';cols=ARRAY['revoked_at']::text[];
 WHEN 'billing_seat' THEN expr='household_id::text||''/''||slot::text';cols=ARRAY[]::text[];
 WHEN 'guardian_enrollment' THEN expr='household_id::text||''/''||enrollment_id::text';cols=ARRAY['state','revision'];
 WHEN 'guardian_child_invitation' THEN expr='household_id::text||''/''||invite_id::text';cols=ARRAY['revoked_at','consumed_at'];
 WHEN 'guardian_child_claim' THEN expr='household_id::text||''/''||claim_id::text';cols=ARRAY['revoked_at'];
 WHEN 'browser_auth' THEN
  expr='guardian_household_id::text||''/''||encode(sha256(convert_to(token_hash,''utf8'')),''hex'')';cols=ARRAY['revoked_at'];
  IF (effect->'before'->>'secret_present') IS DISTINCT FROM (a->>'secret_present') OR (effect->'before'->>'binding_hash') IS DISTINCT FROM (a->>'binding_hash') OR ((a->>'email_present')::boolean AND (effect->'before'->>'email_present') IS DISTINCT FROM 'true') THEN RAISE EXCEPTION 'unsupported_browser_effect';END IF;
  IF a->>'email_present'='false' THEN a=a||jsonb_build_object('email_cipher',NULL);cols=cols||ARRAY['email_cipher'];END IF;
 ELSE RAISE EXCEPTION 'unsupported_effect'; END CASE;
 IF a='null'::jsonb THEN
  IF t<>'billing_seat' THEN RAISE EXCEPTION 'unsupported_delete'; END IF;
  EXECUTE format('DELETE FROM ritc.%I WHERE %s=$1',t,expr) USING k;
 ELSIF effect->'before'='null'::jsonb THEN
  IF t<>'shop_authority' THEN RAISE EXCEPTION 'unsupported_insert'; END IF;
  INSERT INTO ritc.shop_authority SELECT * FROM jsonb_populate_record(NULL::ritc.shop_authority,a);
 ELSE
  SELECT string_agg(format('%I=p.%I',x,x),',') INTO assignments FROM unnest(cols) x;
  EXECUTE format('UPDATE ritc.%I dst SET %s FROM jsonb_populate_record(NULL::ritc.%I,$1) p WHERE %s=$2',t,assignments,t,regexp_replace(expr,'\m(household_id|guardian_household_id|member_id|shop_id|epoch|device_id|window_id|token_hash|grant_id|invite_id|enrollment_id|claim_id|consent_id|child_id|guardian_id|slot)\M','dst.\1','g')) USING a,k;
 END IF;
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_journal_apply_effect(jsonb) FROM PUBLIC;

CREATE FUNCTION ritc.privacy_journal_emit(j uuid,k text,p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE o ritc.privacy_journal_origin;e uuid:=gen_random_uuid();v jsonb;d text;
BEGIN
 SELECT * INTO o FROM ritc.privacy_journal_origin WHERE singleton FOR SHARE;
 IF NOT FOUND OR o.fenced THEN RAISE EXCEPTION 'journal_unavailable'; END IF;
 v=jsonb_build_object('version',1,'eventId',e,'lineage',o.lineage,'schemaDigest',o.schema_digest,'configurationId',o.configuration_id,'jobId',j,'kind',k,'data',p);
 IF octet_length(v::text)>1048576 THEN RAISE EXCEPTION 'journal_too_large'; END IF;
 d=encode(sha256(convert_to(ritc.privacy_journal_canonical(v),'utf8')),'hex');
 INSERT INTO ritc.privacy_journal_outbox(event_id,lineage,job_id,kind,payload,payload_digest) VALUES(e,o.lineage,j,k,v,d);
 RETURN jsonb_build_object('eventId',e,'payloadDigest',d,'payload',v);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_journal_emit(uuid,text,jsonb) FROM PUBLIC;
ALTER FUNCTION ritc.privacy_request(text,text,uuid,uuid,text,text,jsonb,integer,integer) RENAME TO privacy_request_v010;
REVOKE ALL ON FUNCTION ritc.privacy_request_v010(text,text,uuid,uuid,text,text,jsonb,integer,integer) FROM ritc_app;
CREATE FUNCTION ritc.privacy_journal_request(i text,s text,p uuid,j uuid,r text,d text,choices jsonb,rd integer,md integer,attestation jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE hs uuid[];before_rows jsonb;after_rows jsonb;targets jsonb;effects jsonb;event jsonb;job ritc.privacy_job;origin ritc.privacy_journal_origin;t jsonb;
BEGIN
 SELECT * INTO origin FROM ritc.privacy_journal_origin WHERE singleton FOR SHARE;
 IF NOT FOUND OR origin.fenced OR NOT COALESCE(attestation->>'authenticatedMethod'=ANY(ARRAY['otp','password','oauth','sso/saml']),false) OR attestation->>'providerAvailability' IS DISTINCT FROM 'configured_adapter_passed' OR attestation->>'appleGate' IS DISTINCT FROM 'availability_contract_passed' OR (attestation->'policy'->>'receiptRetentionDays')::integer IS DISTINCT FROM rd OR (attestation->'policy'->>'erasureMarkerRetentionDays')::integer IS DISTINCT FROM md OR (attestation->'policy'->>'verifiedBackupRetentionDays')::integer IS NULL OR md<(attestation->'policy'->>'verifiedBackupRetentionDays')::integer OR attestation->>'authenticatedAt' IS NULL OR attestation->>'checkedAt' IS NULL OR attestation->>'configurationId' IS DISTINCT FROM origin.configuration_id OR attestation->>'sessionBindingHash' IS DISTINCT FROM encode(sha256(convert_to(i||E'\n'||s||E'\n'||p::text,'utf8')),'hex') OR (attestation->>'authenticatedAt')::timestamptz<clock_timestamp()-interval '5 minutes' OR (attestation->>'authenticatedAt')::timestamptz>clock_timestamp()+interval '5 seconds' THEN RAISE EXCEPTION 'journal_unavailable'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(encode(sha256(convert_to(i||E'\n'||s,'utf8')),'hex'),0));
 SELECT jsonb_build_object('eventId',event_id,'payloadDigest',payload_digest,'payload',payload) INTO event FROM ritc.privacy_journal_outbox WHERE job_id=j AND kind='acceptance';
 IF event IS NOT NULL THEN
  IF EXISTS(SELECT 1 FROM ritc.privacy_job WHERE job_id=j AND receipt_hash=r AND payload_digest=d AND identity_hash=encode(sha256(convert_to(i||E'\n'||s,'utf8')),'hex')) THEN RETURN event; END IF;
  RAISE EXCEPTION 'key_reused';
 END IF;
 SELECT array_agg(household_id ORDER BY household_id) INTO hs FROM ritc.member WHERE issuer=i AND subject=s AND erased_at IS NULL;
 PERFORM 1 FROM ritc.household WHERE household_id=ANY(hs) ORDER BY household_id FOR UPDATE;
 before_rows=ritc.privacy_journal_snapshot(hs);
 IF jsonb_array_length(before_rows)>10000 THEN RAISE EXCEPTION 'journal_too_large'; END IF;
 PERFORM ritc.privacy_request_v010(i,s,p,j,r,d,choices,rd,md);
 SELECT * INTO STRICT job FROM ritc.privacy_job WHERE job_id=j;
 after_rows=ritc.privacy_journal_snapshot(hs);
 SELECT COALESCE(jsonb_agg(jsonb_build_object('householdId',m.household_id,'memberId',m.member_id,'kind',CASE WHEN m.kind='adult' THEN 'self_adult' ELSE 'explicit_sole_guardian_profile' END,'binding',b->'value','principalKnown',CASE WHEN m.kind='child' THEN EXISTS(SELECT 1 FROM ritc.guardian_child_principal WHERE identity_hash=encode(sha256(convert_to(m.issuer||E'\n'||m.subject,'utf8')),'hex')) ELSE false END) ORDER BY m.household_id,m.member_id),'[]') INTO targets
 FROM ritc.privacy_target pt JOIN ritc.member m USING(household_id,member_id) JOIN jsonb_array_elements(before_rows) b ON b->>'table'='member' AND b->>'key'=m.household_id::text||'/'||m.member_id::text WHERE pt.job_id=j;
 SELECT COALESCE(jsonb_agg(jsonb_build_object('table',COALESCE(b->>'table',a->>'table'),'key',COALESCE(b->>'key',a->>'key'),'before',b->'value','after',a->'value') ORDER BY COALESCE(b->>'table',a->>'table'),COALESCE(b->>'key',a->>'key')),'[]') INTO effects
 FROM jsonb_array_elements(before_rows) b FULL JOIN jsonb_array_elements(after_rows) a ON b->>'table'=a->>'table' AND b->>'key'=a->>'key' WHERE b->'value' IS DISTINCT FROM a->'value';
 event=ritc.privacy_journal_emit(j,'acceptance',jsonb_build_object('identityHash',job.identity_hash,'receiptHash',job.receipt_hash,'requestDigest',job.payload_digest,'acceptedAt',job.created_at,'receiptDays',job.receipt_retention_days,'markerDays',job.marker_retention_days,'receiptUntil',job.receipt_until,'markerUntil',job.marker_until,'attestation',attestation||jsonb_build_object('sqlAdultScopeCheck','passed'),'targets',targets,'effects',effects,'guardianPreimage',(SELECT COALESCE(jsonb_agg(value ORDER BY value->>'table',value->>'key'),'[]') FROM jsonb_array_elements(before_rows) WHERE value->>'table' LIKE 'guardian_%' OR value->>'table'='browser_auth')));
 FOR t IN SELECT value FROM jsonb_array_elements(targets) LOOP
  INSERT INTO ritc.privacy_journal_target VALUES((event->>'eventId')::uuid,(t->>'householdId')::uuid,(t->>'memberId')::uuid,encode(sha256(convert_to(ritc.privacy_journal_canonical(t),'utf8')),'hex'),t);
 END LOOP;
 RETURN event;
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_journal_request(text,text,uuid,uuid,text,text,jsonb,integer,integer,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.privacy_journal_request(text,text,uuid,uuid,text,text,jsonb,integer,integer,jsonb) TO ritc_app;

CREATE FUNCTION ritc.privacy_journal_acknowledge(e uuid,d text,n bigint,h text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM ritc.privacy_journal_outbox WHERE event_id=e AND payload_digest=d) THEN RAISE EXCEPTION 'journal_digest_conflict'; END IF;
 IF EXISTS(SELECT 1 FROM ritc.privacy_journal_ack WHERE event_id=e AND (payload_digest<>d OR head_seq<>n OR head_hash<>h)) THEN RAISE EXCEPTION 'journal_ack_conflict'; END IF;
 INSERT INTO ritc.privacy_journal_ack(event_id,payload_digest,head_seq,head_hash) VALUES(e,d,n,h) ON CONFLICT DO NOTHING;
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_journal_acknowledge(uuid,text,bigint,text) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ritc.privacy_claim(worker_lease uuid) RETURNS TABLE(job_id uuid,issuer text,subject text,app_erased boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$ BEGIN
 RETURN QUERY WITH candidate AS(SELECT j.job_id FROM ritc.privacy_job j WHERE j.state<>'complete' AND j.next_at<=clock_timestamp() AND (j.lease_until IS NULL OR j.lease_until<clock_timestamp())
 AND NOT EXISTS(SELECT 1 FROM ritc.privacy_restore_job r WHERE r.job_id=j.job_id)
 AND EXISTS(SELECT 1 FROM ritc.privacy_journal_origin WHERE singleton AND NOT fenced)
 AND EXISTS(SELECT 1 FROM ritc.privacy_journal_outbox e JOIN ritc.privacy_journal_ack a USING(event_id) WHERE e.job_id=j.job_id AND e.kind='acceptance')
 AND NOT EXISTS(SELECT 1 FROM ritc.privacy_journal_outbox e WHERE e.job_id=j.job_id AND NOT EXISTS(SELECT 1 FROM ritc.privacy_journal_ack a WHERE a.event_id=e.event_id))
 ORDER BY j.created_at,j.job_id FOR UPDATE SKIP LOCKED LIMIT 1)
 UPDATE ritc.privacy_job j SET state='processing',lease_id=worker_lease,lease_until=clock_timestamp()+interval '30 seconds',attempts=attempts+1 FROM candidate c WHERE j.job_id=c.job_id RETURNING j.job_id,j.issuer,j.subject,j.app_erased_at IS NOT NULL;
END $$;
ALTER FUNCTION ritc.privacy_erase_target(uuid,uuid) RENAME TO privacy_erase_target_full_v021;
REVOKE ALL ON FUNCTION ritc.privacy_erase_target_full_v021(uuid,uuid) FROM ritc_worker;
CREATE FUNCTION ritc.privacy_erase_target(j uuid,l uuid) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE t ritc.privacy_target;result boolean;markers jsonb;original_identity text;
BEGIN
 IF EXISTS(SELECT 1 FROM ritc.privacy_restore_job WHERE job_id=j) THEN RETURN false; END IF;
 PERFORM 1 FROM ritc.privacy_journal_origin WHERE singleton AND NOT fenced FOR SHARE;IF NOT FOUND THEN RAISE EXCEPTION 'journal_unavailable';END IF;
 IF NOT EXISTS(SELECT 1 FROM ritc.privacy_job WHERE job_id=j AND lease_id=l AND lease_until>clock_timestamp() AND state='processing') THEN RETURN false; END IF;
 IF EXISTS(SELECT 1 FROM ritc.privacy_journal_outbox e WHERE e.job_id=j AND NOT EXISTS(SELECT 1 FROM ritc.privacy_journal_ack a WHERE a.event_id=e.event_id)) THEN RAISE EXCEPTION 'journal_pending'; END IF;
 SELECT * INTO t FROM ritc.privacy_target WHERE job_id=j AND erased_at IS NULL ORDER BY household_id,member_id LIMIT 1 FOR UPDATE;
 SELECT COALESCE(jsonb_agg(jsonb_build_object('originalHash',encode(sha256(convert_to(environment||E'\n'||original_transaction_id,'utf8')),'hex')) ORDER BY environment,original_transaction_id),'[]') INTO markers FROM ritc.billing_binding WHERE household_id=t.household_id AND purchaser_id=t.member_id;
 SELECT encode(sha256(convert_to(issuer||E'\n'||subject,'utf8')),'hex') INTO original_identity FROM ritc.member WHERE household_id=t.household_id AND member_id=t.member_id;
 result=ritc.privacy_erase_target_full_v021(j,l);
 DELETE FROM ritc.browser_auth WHERE encode(sha256(convert_to(issuer||E'\n'||subject,'utf8')),'hex')=original_identity;
 IF t.member_id IS NOT NULL THEN PERFORM ritc.privacy_journal_emit(j,'target_erased',jsonb_build_object('householdId',t.household_id,'memberId',t.member_id,'retiredPurchases',markers,'erasedAt',(SELECT erased_at FROM ritc.privacy_target WHERE job_id=j AND household_id=t.household_id AND member_id=t.member_id))); END IF;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_target(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.privacy_erase_target(uuid,uuid) TO ritc_worker;
ALTER FUNCTION ritc.privacy_finish(uuid,uuid,boolean,text) RENAME TO privacy_finish_v010;
REVOKE ALL ON FUNCTION ritc.privacy_finish_v010(uuid,uuid,boolean,text) FROM ritc_worker;
CREATE FUNCTION ritc.privacy_finish(j uuid,l uuid,provider_deleted boolean,failure text DEFAULT NULL) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE result boolean;v jsonb;
BEGIN
 IF EXISTS(SELECT 1 FROM ritc.privacy_restore_job WHERE job_id=j) THEN RETURN false; END IF;
 PERFORM 1 FROM ritc.privacy_journal_origin WHERE singleton AND NOT fenced FOR SHARE;IF NOT FOUND THEN RAISE EXCEPTION 'journal_unavailable';END IF;
 IF provider_deleted AND EXISTS(SELECT 1 FROM ritc.privacy_journal_outbox e WHERE e.job_id=j AND NOT EXISTS(SELECT 1 FROM ritc.privacy_journal_ack a WHERE a.event_id=e.event_id)) THEN RAISE EXCEPTION 'journal_pending'; END IF;
 result=ritc.privacy_finish_v010(j,l,provider_deleted,failure);
 IF result THEN
  SELECT jsonb_build_object('appErasedAt',app_erased_at,'providerErasedAt',provider_erased_at,'completedAt',completed_at,'receiptUntil',receipt_until,'markerUntil',marker_until) INTO v FROM ritc.privacy_job WHERE job_id=j;
  PERFORM ritc.privacy_journal_emit(j,CASE WHEN EXISTS(SELECT 1 FROM ritc.privacy_job WHERE job_id=j AND state='complete') THEN 'source_completed' ELSE 'source_pending' END,v);
 END IF;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_finish(uuid,uuid,boolean,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.privacy_finish(uuid,uuid,boolean,text) TO ritc_worker;
CREATE OR REPLACE FUNCTION ritc.privacy_status(request_id uuid,receipt text) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT jsonb_build_object('jobId',job_id,'status',CASE WHEN state='complete' AND NOT EXISTS(SELECT 1 FROM ritc.privacy_journal_outbox e WHERE e.job_id=j.job_id AND NOT EXISTS(SELECT 1 FROM ritc.privacy_journal_ack a WHERE a.event_id=e.event_id)) THEN 'complete' ELSE 'pending' END,'appDataErased',app_erased_at IS NOT NULL,'providerAccountDeleted',provider_erased_at IS NOT NULL AND NOT EXISTS(SELECT 1 FROM ritc.privacy_journal_outbox e WHERE e.job_id=j.job_id AND NOT EXISTS(SELECT 1 FROM ritc.privacy_journal_ack a WHERE a.event_id=e.event_id)),'completedAt',CASE WHEN NOT EXISTS(SELECT 1 FROM ritc.privacy_journal_outbox e WHERE e.job_id=j.job_id AND NOT EXISTS(SELECT 1 FROM ritc.privacy_journal_ack a WHERE a.event_id=e.event_id)) THEN completed_at ELSE NULL END,'receiptExpiresAt',receipt_until) FROM ritc.privacy_job j WHERE job_id=request_id AND receipt_hash=receipt AND (state<>'complete' OR receipt_until>clock_timestamp() OR EXISTS(SELECT 1 FROM ritc.privacy_journal_outbox e WHERE e.job_id=j.job_id AND NOT EXISTS(SELECT 1 FROM ritc.privacy_journal_ack a WHERE a.event_id=e.event_id)))
$$;
ALTER FUNCTION ritc.privacy_cleanup(integer) RENAME TO privacy_cleanup_v010;
REVOKE ALL ON FUNCTION ritc.privacy_cleanup_v010(integer) FROM ritc_worker;
CREATE FUNCTION ritc.privacy_cleanup(batch_size integer) RETURNS TABLE(receipts_cleared integer,jobs_purged integer) LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE old_job record;n integer:=greatest(1,least(batch_size,100));
BEGIN
 receipts_cleared=0;jobs_purged=0;
 FOR old_job IN SELECT j.* FROM ritc.privacy_job j WHERE state='complete' AND receipt_until<=clock_timestamp() AND NOT EXISTS(SELECT 1 FROM ritc.privacy_restore_job r WHERE r.job_id=j.job_id) AND NOT EXISTS(SELECT 1 FROM ritc.privacy_journal_outbox e WHERE e.job_id=j.job_id AND NOT EXISTS(SELECT 1 FROM ritc.privacy_journal_ack a WHERE a.event_id=e.event_id)) ORDER BY marker_until,job_id FOR UPDATE SKIP LOCKED LIMIT n LOOP
  IF old_job.receipt_hash<>repeat('0',64) THEN UPDATE ritc.privacy_job SET receipt_hash=repeat('0',64),payload_digest=repeat('0',64) WHERE job_id=old_job.job_id;receipts_cleared=receipts_cleared+1; END IF;
  IF old_job.marker_until<=clock_timestamp() THEN DELETE FROM ritc.privacy_target WHERE job_id=old_job.job_id;DELETE FROM ritc.identity_erasure WHERE job_id=old_job.job_id;DELETE FROM ritc.privacy_job WHERE job_id=old_job.job_id;jobs_purged=jobs_purged+1;END IF;
 END LOOP;RETURN NEXT;
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_cleanup(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.privacy_cleanup(integer) TO ritc_worker;

-- Owner-only entry point: the local CLI has already verified the pinned journal.
-- Owner compromise is outside the model; app/worker cannot execute this function.
CREATE FUNCTION ritc.privacy_restore_register(r uuid,destination oid,bundle text,head jsonb,events jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE origin ritc.privacy_journal_origin;event jsonb;p jsonb;t jsonb;e jsonb;current_rows jsonb;current_row jsonb;hs uuid[];j uuid;h uuid;m uuid;existing ritc.member;acceptance_id uuid;target_d text;missing_hs uuid[]:='{}';
BEGIN
 IF destination IS DISTINCT FROM (SELECT oid FROM pg_database WHERE datname=current_database()) THEN RAISE EXCEPTION 'destination_oid_conflict'; END IF;
 SELECT * INTO STRICT origin FROM ritc.privacy_journal_origin WHERE singleton FOR UPDATE;
 IF head->>'lineage' IS DISTINCT FROM origin.lineage::text OR head->>'schemaDigest' IS DISTINCT FROM origin.schema_digest OR head->>'configurationId' IS DISTINCT FROM origin.configuration_id OR head->>'fenced' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'journal_origin_conflict'; END IF;
 IF jsonb_array_length(events)>1000 OR octet_length(events::text)>16777216 THEN RAISE EXCEPTION 'journal_too_large'; END IF;
 IF EXISTS(SELECT 1 FROM ritc.privacy_restore_run WHERE run_id=r) THEN
  IF EXISTS(SELECT 1 FROM ritc.privacy_restore_run WHERE run_id=r AND destination_oid=destination AND bundle_digest=bundle AND privacy_restore_run.head=privacy_restore_register.head) THEN RETURN r; END IF;
  RAISE EXCEPTION 'restore_run_conflict';
 END IF;
 -- Validate the complete plan before applying its first effect.
 FOR event IN SELECT value FROM jsonb_array_elements(events) WHERE value->'payload'->>'kind'='acceptance' LOOP
  p=event->'payload'->'data';j=(event->'payload'->>'jobId')::uuid;acceptance_id=(event->>'eventId')::uuid;
  IF event->'payload'->>'lineage'<>origin.lineage::text OR event->'payload'->>'schemaDigest'<>origin.schema_digest OR event->'payload'->>'configurationId'<>origin.configuration_id OR event->>'payloadDigest'<>encode(sha256(convert_to(ritc.privacy_journal_canonical(event->'payload'),'utf8')),'hex') THEN RAISE EXCEPTION 'journal_event_conflict'; END IF;
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
 FOR event IN SELECT value FROM jsonb_array_elements(events) WHERE value->'payload'->>'kind'='acceptance' LOOP
  p=event->'payload'->'data';j=(event->'payload'->>'jobId')::uuid;acceptance_id=(event->>'eventId')::uuid;
  INSERT INTO ritc.privacy_job(job_id,identity_hash,issuer,subject,receipt_hash,payload_digest,created_at,receipt_retention_days,marker_retention_days,receipt_until,marker_until) VALUES(j,p->>'identityHash',NULL,NULL,p->>'receiptHash',p->>'requestDigest',(p->>'acceptedAt')::timestamptz,(p->>'receiptDays')::integer,(p->>'markerDays')::integer,(p->>'receiptUntil')::timestamptz,(p->>'markerUntil')::timestamptz);
  INSERT INTO ritc.identity_erasure VALUES(p->>'identityHash',j,(p->>'markerUntil')::timestamptz);
  INSERT INTO ritc.privacy_restore_job(job_id,run_id,event_id,acceptance_digest,identity_hash,source_observations) VALUES(j,r,acceptance_id,event->>'payloadDigest',p->>'identityHash',COALESCE((SELECT jsonb_agg(value->'payload') FROM jsonb_array_elements(events) WHERE value->'payload'->>'jobId'=j::text AND value->'payload'->>'kind'<>'acceptance'),'[]'));
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
 FOR e IN SELECT value->'payload'->'data' FROM jsonb_array_elements(events) WHERE value->'payload'->>'kind'='target_erased' LOOP
  FOR t IN SELECT value FROM jsonb_array_elements(e->'retiredPurchases') LOOP INSERT INTO ritc.retired_purchase(original_hash) VALUES(t->>'originalHash') ON CONFLICT DO NOTHING; END LOOP;
 END LOOP;
 IF NOT EXISTS(SELECT 1 FROM ritc.privacy_restore_target t WHERE run_id=r AND NOT EXISTS(SELECT 1 FROM ritc.privacy_restore_receipt q WHERE q.event_id=t.event_id AND q.household_id=t.household_id AND q.member_id=t.member_id AND q.target_digest=t.target_digest)) THEN UPDATE ritc.privacy_restore_run SET phase='local_app_erased' WHERE run_id=r; END IF;
 RETURN r;
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_restore_register(uuid,oid,text,jsonb,jsonb) FROM PUBLIC;
CREATE FUNCTION ritc.privacy_restore_claim(r uuid,l uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE j uuid;
BEGIN
 IF NOT pg_has_role(session_user,'ritc_worker','MEMBER') OR pg_has_role(session_user,'ritc_app','MEMBER') THEN RETURN NULL; END IF;
 SELECT p.job_id INTO j FROM ritc.privacy_job p JOIN ritc.privacy_restore_job v USING(job_id) WHERE v.run_id=r AND (p.lease_until IS NULL OR p.lease_until<clock_timestamp()) AND EXISTS(SELECT 1 FROM ritc.privacy_restore_target t WHERE t.job_id=p.job_id AND NOT EXISTS(SELECT 1 FROM ritc.privacy_restore_receipt x WHERE x.event_id=t.event_id AND x.household_id=t.household_id AND x.member_id=t.member_id)) ORDER BY p.job_id FOR UPDATE OF p SKIP LOCKED LIMIT 1;
 IF j IS NULL THEN RETURN NULL; END IF;
 UPDATE ritc.privacy_job SET state='processing',lease_id=l,lease_until=clock_timestamp()+interval '30 seconds',attempts=attempts+1 WHERE job_id=j;RETURN j;
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_restore_claim(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.privacy_restore_claim(uuid,uuid) TO ritc_worker;
CREATE FUNCTION ritc.privacy_restore_erase_next(r uuid,j uuid,l uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE t ritc.privacy_restore_target;v ritc.privacy_restore_job;done boolean;
BEGIN
 IF NOT pg_has_role(session_user,'ritc_worker','MEMBER') OR pg_has_role(session_user,'ritc_app','MEMBER') THEN RETURN jsonb_build_object('applied',false); END IF;
 SELECT * INTO v FROM ritc.privacy_restore_job WHERE run_id=r AND job_id=j FOR UPDATE;
 IF NOT FOUND OR NOT EXISTS(SELECT 1 FROM ritc.privacy_job WHERE job_id=j AND lease_id=l AND lease_until>clock_timestamp() AND state='processing') THEN RETURN jsonb_build_object('applied',false); END IF;
 SELECT * INTO t FROM ritc.privacy_restore_target x WHERE x.run_id=r AND x.job_id=j AND x.present AND NOT EXISTS(SELECT 1 FROM ritc.privacy_restore_receipt q WHERE q.event_id=x.event_id AND q.household_id=x.household_id AND q.member_id=x.member_id) ORDER BY x.household_id,x.member_id LIMIT 1 FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('applied',false,'done',true); END IF;
 IF t.target_digest<>encode(sha256(convert_to(ritc.privacy_journal_canonical(t.target),'utf8')),'hex') OR NOT EXISTS(SELECT 1 FROM ritc.member WHERE household_id=t.household_id AND member_id=t.member_id AND erased_at IS NULL AND kind=t.target->'binding'->>'kind' AND encode(sha256(convert_to(issuer||E'\n'||subject,'utf8')),'hex')=t.target->'binding'->>'identity_hash') THEN RAISE EXCEPTION 'restore_target_binding_conflict'; END IF;
 IF t.event_id<>v.event_id OR NOT EXISTS(SELECT 1 FROM ritc.privacy_target WHERE job_id=j AND household_id=t.household_id AND member_id=t.member_id AND erased_at IS NULL) OR EXISTS(SELECT 1 FROM ritc.privacy_target WHERE job_id=j AND erased_at IS NULL AND (household_id,member_id)<(t.household_id,t.member_id)) THEN RAISE EXCEPTION 'restore_plan_conflict'; END IF;
 done=ritc.privacy_erase_target_full_v021(j,l);
 DELETE FROM ritc.browser_auth WHERE encode(sha256(convert_to(issuer||E'\n'||subject,'utf8')),'hex')=t.target->'binding'->>'identity_hash';
 INSERT INTO ritc.privacy_restore_receipt(event_id,household_id,member_id,target_digest,result) VALUES(t.event_id,t.household_id,t.member_id,t.target_digest,'erased');
 IF done THEN UPDATE ritc.privacy_job SET state='pending',app_erased_at=COALESCE(app_erased_at,clock_timestamp()),lease_id=NULL,lease_until=NULL WHERE job_id=j; END IF;
 IF NOT EXISTS(SELECT 1 FROM ritc.privacy_restore_target x WHERE x.run_id=r AND NOT EXISTS(SELECT 1 FROM ritc.privacy_restore_receipt q WHERE q.event_id=x.event_id AND q.household_id=x.household_id AND q.member_id=x.member_id AND q.target_digest=x.target_digest)) THEN UPDATE ritc.privacy_restore_run SET phase='local_app_erased' WHERE run_id=r; END IF;
 RETURN jsonb_build_object('applied',true,'done',done,'localAppErasureApplied',true,'providerReconciliationRequired',true);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_restore_erase_next(uuid,uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.privacy_restore_erase_next(uuid,uuid,uuid) TO ritc_worker;

-- Preserve the exact accepted close time only within the owner registration
-- transaction holding a verified private plan. GUCs confer no authority.
CREATE OR REPLACE FUNCTION ritc.measurement_close_time() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE context jsonb;old_tuple jsonb;new_tuple jsonb;
BEGIN
 IF TG_OP='INSERT' THEN NEW.measurement_closed_at=CASE WHEN NEW.phase='closed' THEN clock_timestamp() ELSE NULL END;RETURN NEW;END IF;
 IF OLD.phase<>'closed' AND NEW.phase='closed' THEN
  SELECT e.effect INTO context FROM ritc.privacy_restore_effect_context e JOIN ritc.privacy_restore_run r USING(run_id)
  WHERE e.transaction_id=pg_current_xact_id() AND e.actor_oid=(SELECT oid FROM pg_roles WHERE rolname=session_user)
  AND e.table_name='shop' AND e.row_key=NEW.household_id::text||'/'||NEW.shop_id::text
  AND r.destination_oid=(SELECT oid FROM pg_database WHERE datname=current_database()) AND r.phase='quarantined';
  IF context IS NOT NULL THEN
   old_tuple=jsonb_build_object('household_id',OLD.household_id,'shop_id',OLD.shop_id,'shopper_id',OLD.shopper_id,'phase',OLD.phase,'revision',OLD.revision,'authority_epoch',OLD.authority_epoch,'measurement_closed_at',OLD.measurement_closed_at);
   new_tuple=jsonb_build_object('household_id',NEW.household_id,'shop_id',NEW.shop_id,'shopper_id',NEW.shopper_id,'phase',NEW.phase,'revision',NEW.revision,'authority_epoch',NEW.authority_epoch);
   IF context->'before' IS DISTINCT FROM old_tuple OR ((context->'after')-'measurement_closed_at') IS DISTINCT FROM new_tuple OR context->'after'->>'measurement_closed_at' IS NULL THEN RAISE EXCEPTION 'restore_close_preimage_conflict'; END IF;
   NEW.measurement_closed_at=(context->'after'->>'measurement_closed_at')::timestamptz;
  ELSE NEW.measurement_closed_at=clock_timestamp();END IF;
 ELSE NEW.measurement_closed_at=OLD.measurement_closed_at;END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ritc.measurement_close_time() FROM PUBLIC;

-- Projection mirror used only to constrain generated revocation stamps. Every
-- identifier/column is fixed; no context grants SQL or arbitrary row authority.
CREATE FUNCTION ritc.privacy_journal_stamp_projection(t text,r jsonb) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog AS $$
DECLARE cols text[];v jsonb;
BEGIN
 CASE t
 WHEN 'device' THEN cols=ARRAY['household_id','device_id','member_id','revoked_at','guardian_consent_id'];
 WHEN 'replay_window' THEN cols=ARRAY['household_id','window_id','member_id','revoked_at'];
 WHEN 'web_session' THEN
  RETURN jsonb_build_object('household_id',r->'household_id','member_id',r->'member_id','credential_hash',encode(sha256(convert_to(r->>'token_hash','utf8')),'hex'),'revoked_at',r->'revoked_at');
 WHEN 'view_grant' THEN cols=ARRAY['household_id','grant_id','created_by','recipient_id','revoked_at'];
 WHEN 'invite' THEN cols=ARRAY['household_id','invite_id','created_by','redeemed_by','revoked_at'];
 WHEN 'consent' THEN
  SELECT jsonb_object_agg(key,value) INTO v FROM jsonb_each(r) WHERE key=ANY(ARRAY['household_id','consent_id','child_id','guardian_id','granted_at','revoked_at']);
  RETURN v||jsonb_build_object('evidence_hash',encode(sha256(convert_to((r->>'notice_version')||E'\n'||(r->>'verification_ref'),'utf8')),'hex'));
 WHEN 'guardian_relationship' THEN
  SELECT jsonb_object_agg(key,value) INTO v FROM jsonb_each(r) WHERE key=ANY(ARRAY['household_id','child_id','guardian_id','revoked_at']);
  RETURN v||jsonb_build_object('evidence_hash',encode(sha256(convert_to(r->>'proof_ref','utf8')),'hex'));
 WHEN 'guardian_child_invitation' THEN
  SELECT jsonb_object_agg(key,value) INTO v FROM jsonb_each(r) WHERE key=ANY(ARRAY['household_id','invite_id','enrollment_id','revoked_at','consumed_at']);
  RETURN v||jsonb_build_object('binding_hash',encode(sha256(convert_to(ritc.privacy_journal_canonical(r-ARRAY['revoked_at','consumed_at']),'utf8')),'hex'));
 WHEN 'guardian_child_claim' THEN
  SELECT jsonb_object_agg(key,value) INTO v FROM jsonb_each(r) WHERE key=ANY(ARRAY['household_id','claim_id','invite_id','approved_at','finished_at','revoked_at']);
  RETURN v||jsonb_build_object('binding_hash',encode(sha256(convert_to(ritc.privacy_journal_canonical(r-ARRAY['approved_at','finished_at','revoked_at']),'utf8')),'hex'));
 WHEN 'browser_auth' THEN
  RETURN jsonb_build_object('household_id',r->'guardian_household_id','guardian_invite_id',r->'guardian_invite_id','phase',r->'phase','credential_hash',encode(sha256(convert_to(r->>'token_hash','utf8')),'hex'),'revoked_at',r->'revoked_at','email_present',r->>'email_cipher' IS NOT NULL,'secret_present',r->>'secret_cipher' IS NOT NULL,'binding_hash',encode(sha256(convert_to(ritc.privacy_journal_canonical(r-ARRAY['revoked_at','email_cipher','secret_cipher']),'utf8')),'hex'));
 ELSE RAISE EXCEPTION 'unsupported_stamp_projection';END CASE;
 SELECT jsonb_object_agg(key,value) INTO v FROM jsonb_each(r) WHERE key=ANY(cols);RETURN v;
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_journal_stamp_projection(text,jsonb) FROM PUBLIC;
CREATE FUNCTION ritc.privacy_restore_recorded_stamp() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE before_row jsonb;after_row jsonb;key text;context jsonb;
BEGIN
 before_row=ritc.privacy_journal_stamp_projection(TG_TABLE_NAME,to_jsonb(OLD));after_row=ritc.privacy_journal_stamp_projection(TG_TABLE_NAME,to_jsonb(NEW));
 key=(before_row->>'household_id')||'/'||CASE TG_TABLE_NAME
 WHEN 'device' THEN before_row->>'device_id' WHEN 'replay_window' THEN before_row->>'window_id' WHEN 'web_session' THEN before_row->>'credential_hash' WHEN 'view_grant' THEN before_row->>'grant_id' WHEN 'invite' THEN before_row->>'invite_id' WHEN 'consent' THEN before_row->>'consent_id' WHEN 'guardian_relationship' THEN (before_row->>'child_id')||'/'||(before_row->>'guardian_id') WHEN 'guardian_child_invitation' THEN before_row->>'invite_id' WHEN 'guardian_child_claim' THEN before_row->>'claim_id' WHEN 'browser_auth' THEN before_row->>'credential_hash' END;
 SELECT c.effect INTO context FROM ritc.privacy_restore_effect_context c JOIN ritc.privacy_restore_run r USING(run_id) WHERE c.table_name=TG_TABLE_NAME AND c.row_key=key AND c.transaction_id=pg_current_xact_id() AND c.actor_oid=(SELECT oid FROM pg_roles WHERE rolname=session_user) AND r.destination_oid=(SELECT oid FROM pg_database WHERE datname=current_database()) AND r.phase='quarantined';
 IF context IS NULL THEN RETURN NEW;END IF;
 IF after_row IS NOT DISTINCT FROM context->'after' THEN RETURN NEW;END IF;
 IF before_row IS DISTINCT FROM context->'before' OR (after_row-'revoked_at') IS DISTINCT FROM ((context->'after')-'revoked_at') OR context->'after'->>'revoked_at' IS NULL THEN RAISE EXCEPTION 'restore_stamp_preimage_conflict';END IF;
 NEW.revoked_at=(context->'after'->>'revoked_at')::timestamptz;RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_restore_recorded_stamp() FROM PUBLIC;
DO $$ DECLARE t text;BEGIN FOREACH t IN ARRAY ARRAY['device','replay_window','web_session','view_grant','invite','consent','guardian_relationship','guardian_child_invitation','guardian_child_claim','browser_auth'] LOOP
 EXECUTE format('CREATE TRIGGER a_privacy_restore_recorded_stamp BEFORE UPDATE ON ritc.%I FOR EACH ROW EXECUTE FUNCTION ritc.privacy_restore_recorded_stamp()',t);
END LOOP;END $$;
