-- Privacy jobs and restore markers are private; clients only receive a bounded status receipt.
CREATE TABLE ritc.privacy_job (
 job_id uuid PRIMARY KEY, identity_hash text NOT NULL UNIQUE, issuer text, subject text,
 receipt_hash text NOT NULL CHECK(length(receipt_hash)=64), payload_digest text NOT NULL,
 state text NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','processing','complete')),
 app_erased_at timestamptz, provider_erased_at timestamptz, completed_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT now(), receipt_retention_days integer NOT NULL, marker_retention_days integer NOT NULL, receipt_until timestamptz NOT NULL, marker_until timestamptz NOT NULL,
 attempts integer NOT NULL DEFAULT 0, next_at timestamptz NOT NULL DEFAULT now(), lease_id uuid, lease_until timestamptz,
 last_error text CHECK(last_error IN ('provider_unavailable','provider_configuration','storage_unavailable'))
);
CREATE TABLE ritc.identity_erasure (
 identity_hash text PRIMARY KEY, job_id uuid NOT NULL REFERENCES ritc.privacy_job, retain_until timestamptz NOT NULL
);
CREATE TABLE ritc.privacy_target (
 job_id uuid NOT NULL REFERENCES ritc.privacy_job, household_id uuid NOT NULL, member_id uuid NOT NULL,
 erased_at timestamptz, PRIMARY KEY(job_id,household_id,member_id), FOREIGN KEY(household_id,member_id) REFERENCES ritc.member
);
CREATE TABLE ritc.household_exit (
 household_id uuid NOT NULL, member_id uuid NOT NULL, client_key uuid NOT NULL, payload_digest text NOT NULL,
 PRIMARY KEY(household_id,member_id,client_key), FOREIGN KEY(household_id,member_id) REFERENCES ritc.member
);
ALTER TABLE ritc.household ADD COLUMN archived_at timestamptz;
ALTER TABLE ritc.member ADD COLUMN erased_at timestamptz;
DO $$ DECLARE t text; BEGIN FOREACH t IN ARRAY ARRAY['privacy_job','identity_erasure','privacy_target','household_exit'] LOOP
 EXECUTE format('ALTER TABLE ritc.%I ENABLE ROW LEVEL SECURITY',t); EXECUTE format('ALTER TABLE ritc.%I FORCE ROW LEVEL SECURITY',t);
END LOOP; END $$;
CREATE INDEX privacy_job_due ON ritc.privacy_job(next_at) WHERE state<>'complete';
CREATE INDEX privacy_target_member ON ritc.privacy_target(household_id,member_id);
CREATE FUNCTION ritc.identity_blocked(identity_issuer text,identity_subject text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT EXISTS(SELECT 1 FROM ritc.identity_erasure WHERE identity_hash=encode(sha256(convert_to(identity_issuer||E'\n'||identity_subject,'utf8')),'hex'))
$$;
CREATE FUNCTION ritc.privacy_preview(identity_issuer text,identity_subject text,provider_session uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE result jsonb;
BEGIN
 IF NOT ritc.provider_session_live(provider_session,identity_subject::uuid) OR ritc.identity_blocked(identity_issuer,identity_subject) THEN RAISE EXCEPTION 'session_needed'; END IF;
 SELECT jsonb_build_object('adult',NOT EXISTS(SELECT 1 FROM ritc.member WHERE issuer=identity_issuer AND subject=identity_subject AND kind='child'),
 'households',COALESCE(jsonb_agg(jsonb_build_object('householdId',m.household_id,'memberId',m.member_id,'label',h.label,'state',m.state,'organizer',m.organizer,
 'otherAdults',(SELECT COALESCE(jsonb_agg(jsonb_build_object('memberId',a.member_id,'alias',a.alias,'organizer',a.organizer) ORDER BY a.member_id),'[]') FROM ritc.member a WHERE m.organizer AND m.state='active' AND a.household_id=m.household_id AND a.member_id<>m.member_id AND a.kind='adult' AND a.state='active'),
 'activeShops',(SELECT COALESCE(jsonb_agg(jsonb_build_object('shopId',s.shop_id,'revision',s.revision,'authorityEpoch',s.authority_epoch,'phase',s.phase) ORDER BY s.shop_id),'[]') FROM ritc.shop s WHERE s.household_id=m.household_id AND s.shopper_id=m.member_id AND s.phase<>'closed'),
 'soleGuardianChildren',(SELECT COALESCE(jsonb_agg(jsonb_build_object('memberId',c.member_id,'alias',c.alias) ORDER BY c.member_id),'[]') FROM ritc.member c WHERE c.household_id=m.household_id AND c.kind='child' AND c.state='active'
 AND EXISTS(SELECT 1 FROM ritc.guardian_relationship g JOIN ritc.consent n USING(household_id,child_id,guardian_id) WHERE g.household_id=c.household_id AND g.child_id=c.member_id AND g.guardian_id=m.member_id AND g.revoked_at IS NULL AND n.revoked_at IS NULL)
 AND NOT EXISTS(SELECT 1 FROM ritc.guardian_relationship g JOIN ritc.consent n USING(household_id,child_id,guardian_id) JOIN ritc.member a ON a.household_id=g.household_id AND a.member_id=g.guardian_id WHERE g.household_id=c.household_id AND g.child_id=c.member_id AND g.guardian_id<>m.member_id AND g.revoked_at IS NULL AND n.revoked_at IS NULL AND a.state='active'))
 ) ORDER BY m.household_id),'[]')) INTO result FROM ritc.member m JOIN ritc.household h USING(household_id) WHERE m.issuer=identity_issuer AND m.subject=identity_subject AND m.erased_at IS NULL;
 RETURN result;
END $$;
-- Private helper: validates the complete explicit disposition while holding the household lock.
CREATE FUNCTION ritc.privacy_exit_member(target_household uuid,target_member uuid,choice jsonb,deletion_job uuid DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor ritc.member; shoprow ritc.shop; childrow record; replacement uuid; shopchoice jsonb;
BEGIN
 PERFORM 1 FROM ritc.household WHERE household_id=target_household FOR UPDATE;
 SELECT * INTO STRICT actor FROM ritc.member WHERE household_id=target_household AND member_id=target_member;
 IF actor.kind<>'adult' THEN RAISE EXCEPTION 'adult_scope_required'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements_text(COALESCE(choice->'eraseChildProfiles','[]')) requested WHERE NOT EXISTS(
  SELECT 1 FROM ritc.member c JOIN ritc.guardian_relationship g ON g.household_id=c.household_id AND g.child_id=c.member_id JOIN ritc.consent n ON n.household_id=g.household_id AND n.child_id=g.child_id AND n.guardian_id=g.guardian_id
  WHERE c.household_id=target_household AND c.member_id::text=requested AND c.kind='child' AND c.state='active' AND g.guardian_id=target_member AND g.revoked_at IS NULL AND n.revoked_at IS NULL
  AND NOT EXISTS(SELECT 1 FROM ritc.guardian_relationship otherg JOIN ritc.consent othern USING(household_id,child_id,guardian_id) JOIN ritc.member otherm ON otherm.household_id=otherg.household_id AND otherm.member_id=otherg.guardian_id
    WHERE otherg.household_id=target_household AND otherg.child_id=c.member_id AND otherg.guardian_id<>target_member AND otherg.revoked_at IS NULL AND othern.revoked_at IS NULL AND otherm.state='active')
 )) THEN RAISE EXCEPTION 'guardian_disposition_required'; END IF;
 IF actor.organizer AND NOT EXISTS(SELECT 1 FROM ritc.member WHERE household_id=target_household AND member_id<>target_member AND organizer AND state='active') THEN
  IF choice->>'organizer'='transfer' THEN
   replacement=(choice->>'organizerMemberId')::uuid;
   IF NOT EXISTS(SELECT 1 FROM ritc.member WHERE household_id=target_household AND member_id=replacement AND member_id<>target_member AND kind='adult' AND state='active') THEN RAISE EXCEPTION 'invalid_successor'; END IF;
   UPDATE ritc.member SET organizer=true WHERE household_id=target_household AND member_id=replacement;
  ELSIF choice->>'organizer'='archive' THEN UPDATE ritc.household SET archived_at=COALESCE(archived_at,clock_timestamp()) WHERE household_id=target_household;
  ELSE RAISE EXCEPTION 'organizer_disposition_required'; END IF;
 END IF;
 FOR shoprow IN SELECT * FROM ritc.shop WHERE household_id=target_household AND shopper_id=target_member AND phase<>'closed' ORDER BY shop_id FOR UPDATE LOOP
  SELECT v INTO shopchoice FROM jsonb_array_elements(COALESCE(choice->'shops','[]')) v WHERE v->>'shopId'=shoprow.shop_id::text;
  IF shopchoice IS NULL OR (shopchoice->>'revision')::integer<>shoprow.revision OR (shopchoice->>'authorityEpoch')::integer<>shoprow.authority_epoch THEN RAISE EXCEPTION 'shop_disposition_stale'; END IF;
  IF shopchoice->>'action'='transfer' THEN
   replacement=(shopchoice->>'memberId')::uuid;
   IF NOT actor.organizer OR NOT EXISTS(SELECT 1 FROM ritc.member WHERE household_id=target_household AND member_id=replacement AND member_id<>target_member AND kind='adult' AND state='active') THEN RAISE EXCEPTION 'invalid_successor'; END IF;
   UPDATE ritc.shop SET shopper_id=replacement,authority_epoch=authority_epoch+1,revision=revision+1 WHERE household_id=target_household AND shop_id=shoprow.shop_id;
   INSERT INTO ritc.shop_authority(household_id,shop_id,epoch,member_id) VALUES(target_household,shoprow.shop_id,shoprow.authority_epoch+1,replacement);
  ELSIF shopchoice->>'action'='close' THEN UPDATE ritc.shop SET phase='closed',authority_epoch=authority_epoch+1,revision=revision+1 WHERE household_id=target_household AND shop_id=shoprow.shop_id;
  ELSE RAISE EXCEPTION 'shop_disposition_required'; END IF;
 END LOOP;
 FOR childrow IN SELECT c.member_id FROM ritc.member c WHERE c.household_id=target_household AND c.kind='child' AND c.state='active'
 AND EXISTS(SELECT 1 FROM ritc.guardian_relationship g JOIN ritc.consent n USING(household_id,child_id,guardian_id) WHERE g.household_id=c.household_id AND g.child_id=c.member_id AND g.guardian_id=target_member AND g.revoked_at IS NULL AND n.revoked_at IS NULL)
 AND NOT EXISTS(SELECT 1 FROM ritc.guardian_relationship g JOIN ritc.consent n USING(household_id,child_id,guardian_id) JOIN ritc.member a ON a.household_id=g.household_id AND a.member_id=g.guardian_id WHERE g.household_id=c.household_id AND g.child_id=c.member_id AND g.guardian_id<>target_member AND g.revoked_at IS NULL AND n.revoked_at IS NULL AND a.state='active') LOOP
  IF deletion_job IS NULL OR NOT COALESCE(choice->'eraseChildProfiles','[]') ? childrow.member_id::text THEN RAISE EXCEPTION 'guardian_disposition_required'; END IF;
  INSERT INTO ritc.privacy_target(job_id,household_id,member_id) VALUES(deletion_job,target_household,childrow.member_id) ON CONFLICT DO NOTHING;
  UPDATE ritc.member SET state='revoked',can_contribute=false WHERE household_id=target_household AND member_id=childrow.member_id;
  UPDATE ritc.device SET revoked_at=COALESCE(revoked_at,clock_timestamp()) WHERE household_id=target_household AND member_id=childrow.member_id;
  UPDATE ritc.replay_window SET revoked_at=COALESCE(revoked_at,clock_timestamp()) WHERE household_id=target_household AND member_id=childrow.member_id;
  UPDATE ritc.view_grant SET revoked_at=COALESCE(revoked_at,clock_timestamp()) WHERE household_id=target_household AND (created_by=childrow.member_id OR recipient_id=childrow.member_id);
 END LOOP;
 UPDATE ritc.member SET state='revoked',organizer=false,can_contribute=false WHERE household_id=target_household AND member_id=target_member;
 UPDATE ritc.device SET revoked_at=COALESCE(revoked_at,clock_timestamp()) WHERE household_id=target_household AND member_id=target_member;
 UPDATE ritc.replay_window SET revoked_at=COALESCE(revoked_at,clock_timestamp()) WHERE household_id=target_household AND member_id=target_member;
 UPDATE ritc.web_session SET revoked_at=COALESCE(revoked_at,clock_timestamp()) WHERE household_id=target_household AND member_id=target_member;
 UPDATE ritc.view_grant SET revoked_at=COALESCE(revoked_at,clock_timestamp()) WHERE household_id=target_household AND (created_by=target_member OR recipient_id=target_member);
 UPDATE ritc.invite SET revoked_at=COALESCE(revoked_at,clock_timestamp()) WHERE household_id=target_household AND (created_by=target_member OR redeemed_by=target_member);
 UPDATE ritc.consent SET revoked_at=clock_timestamp() WHERE household_id=target_household AND guardian_id=target_member AND revoked_at IS NULL;
 UPDATE ritc.guardian_relationship SET revoked_at=COALESCE(revoked_at,clock_timestamp()) WHERE household_id=target_household AND guardian_id=target_member;
 DELETE FROM ritc.billing_seat WHERE household_id=target_household AND (member_id=target_member OR EXISTS(SELECT 1 FROM ritc.billing_state WHERE household_id=target_household AND purchaser_id=target_member));
END $$;
CREATE FUNCTION ritc.privacy_request(identity_issuer text,identity_subject text,provider_session uuid,request_id uuid,receipt text,payload text,choices jsonb,receipt_days integer,marker_days integer) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE identity_key text:=encode(sha256(convert_to(identity_issuer||E'\n'||identity_subject,'utf8')),'hex'); memberrow record; choice jsonb;
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended(identity_key,0));
 IF EXISTS(SELECT 1 FROM ritc.privacy_job WHERE job_id=request_id AND identity_hash=identity_key AND receipt_hash=receipt AND payload_digest=payload) THEN RETURN request_id; END IF;
 IF EXISTS(SELECT 1 FROM ritc.privacy_job WHERE job_id=request_id OR identity_hash=identity_key) THEN RAISE EXCEPTION 'key_reused'; END IF;
 IF receipt_days NOT BETWEEN 1 AND 365 OR marker_days NOT BETWEEN receipt_days AND 3650 OR length(receipt)<>64 THEN RAISE EXCEPTION 'invalid_policy'; END IF;
 IF NOT ritc.provider_session_live(provider_session,identity_subject::uuid) OR ritc.identity_blocked(identity_issuer,identity_subject) THEN RAISE EXCEPTION 'session_needed'; END IF;
 IF EXISTS(SELECT 1 FROM ritc.member WHERE issuer=identity_issuer AND subject=identity_subject AND kind='child') THEN RAISE EXCEPTION 'adult_scope_required'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(choices) selected WHERE NOT EXISTS(SELECT 1 FROM ritc.member m WHERE m.household_id::text=selected->>'householdId' AND m.issuer=identity_issuer AND m.subject=identity_subject AND m.erased_at IS NULL)) THEN RAISE EXCEPTION 'unavailable'; END IF;
 -- Lock all affected households in a fixed order before checking responsibilities and changing access.
 PERFORM 1 FROM ritc.household h WHERE EXISTS(SELECT 1 FROM ritc.member m WHERE m.household_id=h.household_id AND m.issuer=identity_issuer AND m.subject=identity_subject) ORDER BY h.household_id FOR UPDATE;
 INSERT INTO ritc.privacy_job(job_id,identity_hash,issuer,subject,receipt_hash,payload_digest,receipt_retention_days,marker_retention_days,receipt_until,marker_until) VALUES(request_id,identity_key,identity_issuer,identity_subject,receipt,payload,receipt_days,marker_days,clock_timestamp()+make_interval(days=>receipt_days),clock_timestamp()+make_interval(days=>marker_days));
 FOR memberrow IN SELECT household_id,member_id FROM ritc.member WHERE issuer=identity_issuer AND subject=identity_subject AND erased_at IS NULL ORDER BY household_id LOOP
  SELECT v INTO choice FROM jsonb_array_elements(choices) v WHERE v->>'householdId'=memberrow.household_id::text;
  IF choice IS NULL THEN choice=jsonb_build_object('householdId',memberrow.household_id,'organizer','none','shops','[]'::jsonb,'eraseChildProfiles','[]'::jsonb); END IF;
  INSERT INTO ritc.privacy_target(job_id,household_id,member_id) VALUES(request_id,memberrow.household_id,memberrow.member_id);
  PERFORM ritc.privacy_exit_member(memberrow.household_id,memberrow.member_id,choice,request_id);
 END LOOP;
 INSERT INTO ritc.identity_erasure(identity_hash,job_id,retain_until) VALUES(identity_key,request_id,clock_timestamp()+make_interval(days=>marker_days));
 -- The identity marker immediately blocks all browser use, including refresh.
 -- Browser rows are cleared by the worker, avoiding identity-lock/browser-row-lock inversion.
 RETURN request_id;
END $$;
CREATE FUNCTION ritc.privacy_status(request_id uuid,receipt text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT jsonb_build_object('jobId',job_id,'status',CASE WHEN state='complete' THEN 'complete' ELSE 'pending' END,'appDataErased',app_erased_at IS NOT NULL,'providerAccountDeleted',provider_erased_at IS NOT NULL,'completedAt',completed_at,'receiptExpiresAt',receipt_until) FROM ritc.privacy_job WHERE job_id=request_id AND receipt_hash=receipt AND (state<>'complete' OR receipt_until>clock_timestamp())
$$;
CREATE FUNCTION ritc.leave_household(identity_issuer text,identity_subject text,provider_session uuid,target_household uuid,request_id uuid,payload text,choice jsonb) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE memberid uuid;
BEGIN
 IF NOT ritc.provider_session_live(provider_session,identity_subject::uuid) OR ritc.identity_blocked(identity_issuer,identity_subject) THEN RAISE EXCEPTION 'session_needed'; END IF;
 PERFORM 1 FROM ritc.household WHERE household_id=target_household FOR UPDATE;
 SELECT member_id INTO memberid FROM ritc.member WHERE household_id=target_household AND issuer=identity_issuer AND subject=identity_subject AND kind='adult';
 IF memberid IS NULL THEN RAISE EXCEPTION 'unavailable'; END IF;
 IF EXISTS(SELECT 1 FROM ritc.household_exit WHERE household_id=target_household AND member_id=memberid AND client_key=request_id AND payload_digest=payload) THEN RETURN true; END IF;
 IF EXISTS(SELECT 1 FROM ritc.household_exit WHERE household_id=target_household AND member_id=memberid AND client_key=request_id) THEN RAISE EXCEPTION 'key_reused'; END IF;
 IF NOT EXISTS(SELECT 1 FROM ritc.member WHERE household_id=target_household AND member_id=memberid AND state='active') THEN RAISE EXCEPTION 'unavailable'; END IF;
 PERFORM ritc.privacy_exit_member(target_household,memberid,choice,NULL);
 INSERT INTO ritc.household_exit VALUES(target_household,memberid,request_id,payload);RETURN true;
END $$;
REVOKE ALL ON FUNCTION ritc.identity_blocked(text,text),ritc.privacy_preview(text,text,uuid),ritc.privacy_exit_member(uuid,uuid,jsonb,uuid),ritc.privacy_request(text,text,uuid,uuid,text,text,jsonb,integer,integer),ritc.privacy_status(uuid,text),ritc.leave_household(text,text,uuid,uuid,uuid,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.identity_blocked(text,text),ritc.privacy_preview(text,text,uuid),ritc.privacy_request(text,text,uuid,uuid,text,text,jsonb,integer,integer),ritc.privacy_status(uuid,text),ritc.leave_household(text,text,uuid,uuid,uuid,text,jsonb) TO ritc_app;
-- A retired original purchase never becomes a fresh binding merely because a generic receipt expired.
-- Purging this content-free marker requires a separately proven Apple replay/renewal horizon.
CREATE TABLE ritc.retired_purchase (original_hash text PRIMARY KEY CHECK(length(original_hash)=64),retired_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE ritc.retired_purchase ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.retired_purchase FORCE ROW LEVEL SECURITY;
CREATE FUNCTION ritc.purchase_retired(apple_environment text,original_id text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT EXISTS(SELECT 1 FROM ritc.retired_purchase WHERE original_hash=encode(sha256(convert_to(apple_environment||E'\n'||original_id,'utf8')),'hex'))
$$;
REVOKE ALL ON FUNCTION ritc.purchase_retired(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.purchase_retired(text,text) TO ritc_app;
CREATE FUNCTION ritc.privacy_erasure_authorized() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT pg_has_role(session_user,'ritc_worker','MEMBER') AND EXISTS(SELECT 1 FROM ritc.privacy_job WHERE job_id::text=current_setting('app.erasure_job',true) AND lease_id::text=current_setting('app.erasure_lease',true) AND lease_until>clock_timestamp() AND state='processing')
$$;
REVOKE ALL ON FUNCTION ritc.privacy_erasure_authorized() FROM PUBLIC;
CREATE OR REPLACE FUNCTION ritc.immutable_row() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF ritc.privacy_erasure_authorized() THEN RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END; END IF;
 RAISE EXCEPTION 'immutable evidence' USING ERRCODE='23514';
END $$;
-- Trigger invocation requires EXECUTE on its helper for ordinary runtime writes, but the helper
-- cannot confer authority: the caller must be the separate worker login and hold a live job lease.
GRANT EXECUTE ON FUNCTION ritc.privacy_erasure_authorized() TO ritc_app,ritc_worker;
CREATE FUNCTION ritc.privacy_claim(worker_lease uuid) RETURNS TABLE(job_id uuid,issuer text,subject text,app_erased boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 RETURN QUERY WITH candidate AS(SELECT j.job_id FROM ritc.privacy_job j WHERE j.state<>'complete' AND j.next_at<=clock_timestamp() AND (j.lease_until IS NULL OR j.lease_until<clock_timestamp()) ORDER BY j.created_at,j.job_id FOR UPDATE SKIP LOCKED LIMIT 1)
 UPDATE ritc.privacy_job j SET state='processing',lease_id=worker_lease,lease_until=clock_timestamp()+interval '30 seconds',attempts=attempts+1 FROM candidate c WHERE j.job_id=c.job_id RETURNING j.job_id,j.issuer,j.subject,j.app_erased_at IS NOT NULL;
END $$;
CREATE FUNCTION ritc.privacy_erase_target(request_id uuid,worker_lease uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE target record; purchase record; h uuid; m uuid;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM ritc.privacy_job WHERE job_id=request_id AND lease_id=worker_lease AND lease_until>clock_timestamp() AND state='processing') THEN RETURN false; END IF;
 SELECT * INTO target FROM ritc.privacy_target WHERE job_id=request_id AND erased_at IS NULL ORDER BY household_id,member_id LIMIT 1 FOR UPDATE;
 IF NOT FOUND THEN
  -- Provider identity is retained only until the privileged deletion adapter confirms its removal.
  UPDATE ritc.privacy_job SET app_erased_at=COALESCE(app_erased_at,clock_timestamp()) WHERE job_id=request_id; RETURN true;
 END IF;
 h=target.household_id;m=target.member_id;PERFORM 1 FROM ritc.household WHERE household_id=h FOR UPDATE;
 PERFORM set_config('app.erasure_job',request_id::text,true),set_config('app.erasure_lease',worker_lease::text,true);
 DELETE FROM ritc.preview p WHERE p.household_id=h AND (p.actor_id=m OR p.request_id IN(SELECT r.request_id FROM ritc.request r WHERE r.household_id=h AND r.author_id=m));
 DELETE FROM ritc.operation_response r USING ritc.operation o WHERE r.household_id=h AND o.household_id=r.household_id AND o.operation_id=r.operation_id AND o.actor_id=m;
 -- Personal source text is removed from linked basket projections; other contributors' requests remain.
 UPDATE ritc.basket_line b SET original_item='Removed item' WHERE b.household_id=h AND (EXISTS(SELECT 1 FROM ritc.shop_snapshot ss JOIN ritc.operation o USING(household_id,operation_id),jsonb_array_elements(COALESCE(ss.snapshot->'lines','[]')) line WHERE ss.household_id=h AND ss.shop_id=b.shop_id AND o.actor_id=m AND line->>'lineId'=b.line_id::text AND line->>'originalItem'=b.original_item) OR EXISTS(SELECT 1 FROM ritc.request_link l JOIN ritc.request r USING(household_id,request_id) WHERE l.household_id=h AND l.shop_id=b.shop_id AND l.line_id=b.line_id AND r.author_id=m));
 WITH source_lines AS MATERIALIZED (SELECT ss.shop_id,line->>'lineId' AS line_id,line->>'originalItem' AS original_item FROM ritc.shop_snapshot ss JOIN ritc.operation o USING(household_id,operation_id),jsonb_array_elements(COALESCE(ss.snapshot->'lines','[]')) line WHERE ss.household_id=h AND o.actor_id=m)
 UPDATE ritc.shop_snapshot s SET snapshot=jsonb_set(s.snapshot,'{lines}',COALESCE((SELECT jsonb_agg(CASE WHEN EXISTS(SELECT 1 FROM source_lines src WHERE src.shop_id=s.shop_id AND src.line_id=line->>'lineId' AND src.original_item=line->>'originalItem') OR EXISTS(SELECT 1 FROM ritc.basket_line b WHERE b.household_id=h AND b.shop_id=s.shop_id AND b.line_id::text=line->>'lineId' AND b.original_item='Removed item') THEN jsonb_set(line,'{originalItem}','"Removed item"') ELSE line END) FROM jsonb_array_elements(COALESCE(s.snapshot->'lines','[]')) line),'[]')),digest=repeat('0',64)
 WHERE s.household_id=h AND (EXISTS(SELECT 1 FROM source_lines src WHERE src.shop_id=s.shop_id) OR EXISTS(SELECT 1 FROM ritc.basket_line b WHERE b.household_id=h AND b.shop_id=s.shop_id AND b.original_item='Removed item'));
 UPDATE ritc.request SET original_item='Removed request',own_quantity=NULL,clarification=NULL,status='withdrawn',revision=revision+1,authored_at=date_trunc('day',authored_at) WHERE household_id=h AND author_id=m;
 DELETE FROM ritc.request_link l USING ritc.request r WHERE l.household_id=h AND r.household_id=l.household_id AND r.request_id=l.request_id AND r.author_id=m;
 UPDATE ritc.operation SET payload_digest=repeat('0',64) WHERE household_id=h AND actor_id=m;
 DELETE FROM ritc.helper_proposal WHERE household_id=h AND actor_id=m;
 UPDATE ritc.view_grant SET projection='{"items":[],"shopLabel":"Removed view","language":"en"}'::jsonb,revoked_at=COALESCE(revoked_at,clock_timestamp()) WHERE household_id=h AND created_by=m;
 DELETE FROM ritc.invite WHERE household_id=h AND (created_by=m OR redeemed_by=m);
 DELETE FROM ritc.consent WHERE household_id=h AND (guardian_id=m OR child_id=m);
 DELETE FROM ritc.guardian_relationship WHERE household_id=h AND (guardian_id=m OR child_id=m);
 DELETE FROM ritc.web_session WHERE household_id=h AND member_id=m;
 UPDATE ritc.device SET session_id='erased',token_hash=encode(sha256(convert_to('erased:'||device_id::text,'utf8')),'hex'),revoked_at=COALESCE(revoked_at,clock_timestamp()) WHERE household_id=h AND member_id=m;
 UPDATE ritc.household SET label='Household' WHERE household_id=h AND EXISTS(SELECT 1 FROM ritc.household_creation WHERE household_id=h AND member_id=m);
 DELETE FROM ritc.household_creation WHERE household_id=h AND member_id=m;
 DELETE FROM ritc.household_exit WHERE household_id=h AND member_id=m;
 FOR purchase IN SELECT environment,original_transaction_id FROM ritc.billing_binding WHERE household_id=h AND purchaser_id=m ORDER BY environment,original_transaction_id LOOP
  PERFORM pg_advisory_xact_lock(hashtextextended('apple-retired:'||purchase.environment||E'\n'||purchase.original_transaction_id,0));
 END LOOP;
 INSERT INTO ritc.retired_purchase(original_hash) SELECT encode(sha256(convert_to(environment||E'\n'||original_transaction_id,'utf8')),'hex') FROM ritc.billing_binding WHERE household_id=h AND purchaser_id=m ON CONFLICT DO NOTHING;
 DELETE FROM ritc.billing_seat WHERE household_id=h AND (member_id=m OR EXISTS(SELECT 1 FROM ritc.billing_state WHERE household_id=h AND purchaser_id=m));
 DELETE FROM ritc.billing_state WHERE household_id=h AND purchaser_id=m;
 DELETE FROM ritc.billing_delivery WHERE household_id=h AND purchaser_id=m;
 DELETE FROM ritc.billing_binding WHERE household_id=h AND purchaser_id=m;
 DELETE FROM ritc.billing_event WHERE household_id=h AND actor_id=m;
 DELETE FROM ritc.billing_account WHERE household_id=h AND purchaser_id=m;
 UPDATE ritc.member SET issuer='urn:ritc:erased',subject=member_id::text,alias='Removed member',state='revoked',organizer=false,can_contribute=false,erased_at=clock_timestamp() WHERE household_id=h AND member_id=m;
 UPDATE ritc.privacy_target SET erased_at=clock_timestamp() WHERE job_id=request_id AND household_id=h AND member_id=m;
 RETURN NOT EXISTS(SELECT 1 FROM ritc.privacy_target WHERE job_id=request_id AND erased_at IS NULL);
END $$;
CREATE FUNCTION ritc.privacy_finish(request_id uuid,worker_lease uuid,provider_deleted boolean,failure text DEFAULT NULL) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE job ritc.privacy_job;
BEGIN
 SELECT * INTO job FROM ritc.privacy_job WHERE job_id=request_id AND lease_id=worker_lease AND lease_until>clock_timestamp() AND state='processing' FOR UPDATE;
 IF NOT FOUND THEN RETURN false; END IF;
 IF failure IS NOT NULL AND failure NOT IN ('provider_unavailable','provider_configuration','storage_unavailable') THEN RAISE EXCEPTION 'invalid outcome'; END IF;
 IF NOT EXISTS(SELECT 1 FROM ritc.privacy_target WHERE job_id=request_id AND erased_at IS NULL) THEN
  DELETE FROM ritc.browser_auth WHERE issuer=job.issuer AND subject=job.subject;
 END IF;
 IF provider_deleted AND NOT EXISTS(SELECT 1 FROM ritc.privacy_target WHERE job_id=request_id AND erased_at IS NULL) THEN
  UPDATE ritc.privacy_job SET state='complete',app_erased_at=COALESCE(app_erased_at,clock_timestamp()),provider_erased_at=clock_timestamp(),completed_at=clock_timestamp(),issuer=NULL,subject=NULL,receipt_until=clock_timestamp()+make_interval(days=>receipt_retention_days),marker_until=clock_timestamp()+make_interval(days=>marker_retention_days),lease_id=NULL,lease_until=NULL,last_error=NULL WHERE job_id=request_id;
  UPDATE ritc.identity_erasure SET retain_until=clock_timestamp()+make_interval(days=>job.marker_retention_days) WHERE job_id=request_id;
 ELSE
  UPDATE ritc.privacy_job SET state='pending',app_erased_at=CASE WHEN NOT EXISTS(SELECT 1 FROM ritc.privacy_target WHERE job_id=request_id AND erased_at IS NULL) THEN COALESCE(app_erased_at,clock_timestamp()) ELSE app_erased_at END,
   next_at=clock_timestamp()+make_interval(secs=>least(3600,30*power(2,least(attempts,7)))::integer),lease_id=NULL,lease_until=NULL,last_error=failure WHERE job_id=request_id;
 END IF;
 RETURN true;
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_claim(uuid),ritc.privacy_erase_target(uuid,uuid),ritc.privacy_finish(uuid,uuid,boolean,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.privacy_claim(uuid),ritc.privacy_erase_target(uuid,uuid),ritc.privacy_finish(uuid,uuid,boolean,text) TO ritc_worker;
CREATE FUNCTION ritc.privacy_cleanup(batch_size integer) RETURNS TABLE(receipts_cleared integer,jobs_purged integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE n integer:=greatest(1,least(batch_size,100));old_job record;
BEGIN
 WITH candidates AS(SELECT job_id FROM ritc.privacy_job WHERE state='complete' AND receipt_until<=clock_timestamp() AND receipt_hash<>repeat('0',64) ORDER BY receipt_until,job_id FOR UPDATE SKIP LOCKED LIMIT n)
 UPDATE ritc.privacy_job j SET receipt_hash=repeat('0',64),payload_digest=repeat('0',64) FROM candidates c WHERE j.job_id=c.job_id;
 GET DIAGNOSTICS receipts_cleared=ROW_COUNT;jobs_purged=0;
 FOR old_job IN SELECT job_id FROM ritc.privacy_job WHERE state='complete' AND marker_until<=clock_timestamp() AND receipt_until<=clock_timestamp() ORDER BY marker_until,job_id FOR UPDATE SKIP LOCKED LIMIT n LOOP
  DELETE FROM ritc.privacy_target WHERE job_id=old_job.job_id;
  DELETE FROM ritc.identity_erasure WHERE job_id=old_job.job_id;
  DELETE FROM ritc.privacy_job WHERE job_id=old_job.job_id;jobs_purged=jobs_purged+1;
 END LOOP;
 RETURN NEXT;
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_cleanup(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.privacy_cleanup(integer) TO ritc_worker;
