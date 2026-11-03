-- Provider verification, explicit guardian permission and child-device pairing are
-- separate evidence. ritc_app cannot create provider evidence or old consent.
CREATE TABLE ritc.guardian_enrollment (
 household_id uuid NOT NULL, enrollment_id uuid NOT NULL, guardian_id uuid NOT NULL, guardian_device_id uuid NOT NULL,
 guardian_issuer text NOT NULL, guardian_subject text NOT NULL, guardian_session text NOT NULL,
 child_id uuid NOT NULL, child_alias text CHECK(length(child_alias) BETWEEN 1 AND 80),
 notice_version text NOT NULL CHECK(length(notice_version) BETWEEN 1 AND 100), notice_digest text NOT NULL CHECK(notice_digest ~ '^[0-9a-f]{64}$'),
 method_version text NOT NULL CHECK(length(method_version) BETWEEN 1 AND 100), language text NOT NULL CHECK(language IN('en','es')),
 child_location text NOT NULL CHECK(child_location ~ '^US(-[A-Z]{2})?$'), scope text NOT NULL DEFAULT 'own_requests' CHECK(scope='own_requests'),
 declaration text NOT NULL CHECK(declaration='parent_or_legal_guardian'), revision integer NOT NULL DEFAULT 1 CHECK(revision>0),
 state text NOT NULL DEFAULT 'awaiting_verification' CHECK(state IN('awaiting_verification','verification_pending','verification_uncertain','verified','consented','child_claimed','child_approved','active','cancelled','expired','withdrawn')),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(), expires_at timestamptz NOT NULL,
 verified_at timestamptz, consented_at timestamptz, consent_id uuid, claim_id uuid,
 PRIMARY KEY(household_id,enrollment_id), FOREIGN KEY(household_id,guardian_id,guardian_device_id) REFERENCES ritc.device(household_id,member_id,device_id),
 CHECK(expires_at>created_at), CHECK(child_id<>guardian_id)
);
CREATE INDEX guardian_enrollment_guardian ON ritc.guardian_enrollment(household_id,guardian_id);
CREATE INDEX guardian_enrollment_child ON ritc.guardian_enrollment(household_id,child_id);
CREATE TABLE ritc.guardian_attempt (
 household_id uuid NOT NULL, enrollment_id uuid NOT NULL, attempt_id uuid NOT NULL,
 organization_id text NOT NULL, product_id uuid, environment text NOT NULL CHECK(environment IN('test','production')),
 nonce_hash text NOT NULL CHECK(nonce_hash ~ '^[0-9a-f]{64}$'), email_digest text NOT NULL CHECK(email_digest ~ '^[0-9a-f]{64}$'),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(), expires_at timestamptz NOT NULL,
 PRIMARY KEY(household_id,enrollment_id), UNIQUE(household_id,attempt_id),
 FOREIGN KEY(household_id,enrollment_id) REFERENCES ritc.guardian_enrollment ON DELETE CASCADE
);
CREATE TABLE ritc.guardian_provider_event (
 household_id uuid NOT NULL, attempt_id uuid NOT NULL, transaction_id text NOT NULL CHECK(length(transaction_id) BETWEEN 1 AND 256),
 event_digest text NOT NULL CHECK(event_digest ~ '^[0-9a-f]{64}$'), verified_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(household_id,attempt_id), UNIQUE(transaction_id),
 FOREIGN KEY(household_id,attempt_id) REFERENCES ritc.guardian_attempt(household_id,attempt_id) ON DELETE CASCADE
);
CREATE TABLE ritc.guardian_child_invitation (
 household_id uuid NOT NULL, invite_id uuid NOT NULL, enrollment_id uuid NOT NULL,
 secret_hash text NOT NULL CHECK(secret_hash ~ '^[0-9a-f]{64}$'), expires_at timestamptz NOT NULL,
 revoked_at timestamptz, consumed_at timestamptz,
 PRIMARY KEY(household_id,invite_id), UNIQUE(household_id,enrollment_id),
 FOREIGN KEY(household_id,enrollment_id) REFERENCES ritc.guardian_enrollment ON DELETE CASCADE
);
CREATE TABLE ritc.guardian_child_claim (
 household_id uuid NOT NULL, claim_id uuid NOT NULL, invite_id uuid NOT NULL,
 issuer text NOT NULL, subject text NOT NULL, session_id text NOT NULL, pairing_hash text NOT NULL CHECK(pairing_hash ~ '^[0-9a-f]{64}$'),
 expires_at timestamptz NOT NULL, approved_at timestamptz, finished_at timestamptz, revoked_at timestamptz,
 device_id uuid, device_hash text,
 PRIMARY KEY(household_id,claim_id), UNIQUE(household_id,invite_id),
 FOREIGN KEY(household_id,invite_id) REFERENCES ritc.guardian_child_invitation ON DELETE CASCADE
);
CREATE TABLE ritc.guardian_intent (
 household_id uuid NOT NULL, issuer text NOT NULL, subject text NOT NULL, session_id text NOT NULL, client_key uuid NOT NULL,
 enrollment_id uuid NOT NULL, kind text NOT NULL, payload_digest text NOT NULL CHECK(payload_digest ~ '^[0-9a-f]{64}$'), response jsonb NOT NULL,
 PRIMARY KEY(household_id,issuer,subject,client_key),
 FOREIGN KEY(household_id,enrollment_id) REFERENCES ritc.guardian_enrollment ON DELETE CASCADE
);
CREATE INDEX guardian_intent_enrollment ON ritc.guardian_intent(household_id,enrollment_id);
ALTER TABLE ritc.device ADD COLUMN guardian_consent_id uuid;

DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['guardian_enrollment','guardian_attempt','guardian_provider_event','guardian_child_invitation','guardian_child_claim','guardian_intent'] LOOP
  EXECUTE format('ALTER TABLE ritc.%I ENABLE ROW LEVEL SECURITY',t);
  EXECUTE format('ALTER TABLE ritc.%I FORCE ROW LEVEL SECURITY',t);
  EXECUTE format('CREATE POLICY tenant_scope ON ritc.%I USING(household_id::text=(SELECT current_setting(''app.household_id'',true))) WITH CHECK(household_id::text=(SELECT current_setting(''app.household_id'',true)))',t);
 END LOOP;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='ritc_guardian_verifier') THEN CREATE ROLE ritc_guardian_verifier NOLOGIN NOSUPERUSER NOBYPASSRLS; END IF;
END $$;
GRANT USAGE ON SCHEMA ritc TO ritc_guardian_verifier;
GRANT SELECT ON ritc.guardian_enrollment,ritc.guardian_attempt TO ritc_guardian_verifier;
GRANT SELECT ON ritc.guardian_enrollment,ritc.guardian_attempt,ritc.guardian_provider_event,ritc.guardian_child_invitation,ritc.guardian_child_claim,ritc.guardian_intent TO ritc_app;
GRANT INSERT(household_id,enrollment_id,guardian_id,guardian_device_id,guardian_issuer,guardian_subject,guardian_session,child_id,notice_version,notice_digest,method_version,language,child_location,declaration,expires_at) ON ritc.guardian_enrollment TO ritc_app;
GRANT UPDATE(child_alias,revision,state,consented_at,claim_id) ON ritc.guardian_enrollment TO ritc_app;
GRANT INSERT ON ritc.guardian_attempt,ritc.guardian_child_invitation,ritc.guardian_child_claim,ritc.guardian_intent TO ritc_app;
GRANT UPDATE(revoked_at,consumed_at) ON ritc.guardian_child_invitation TO ritc_app;
GRANT UPDATE(approved_at,revoked_at) ON ritc.guardian_child_claim TO ritc_app;

-- Server lookup: exact current member/device/subject/provider session and confirmed
-- provider email. User metadata and client-supplied email are never consulted.
-- Supabase Auth's official models/user.go defines email + email_confirmed_at.
CREATE FUNCTION ritc.guardian_confirmed_email(h uuid,g uuid,d uuid,i text,s text,p text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE email text;
BEGIN
 IF h::text IS DISTINCT FROM current_setting('app.household_id',true) OR NOT EXISTS(
  SELECT 1 FROM ritc.member m JOIN ritc.device v USING(household_id,member_id)
  WHERE m.household_id=h AND m.member_id=g AND m.kind='adult' AND m.state='active' AND m.erased_at IS NULL
  AND m.issuer=i AND m.subject=s AND v.device_id=d AND v.session_id=p AND v.revoked_at IS NULL
 ) THEN RETURN NULL; END IF;
 IF NOT ritc.provider_session_live(p::uuid,s::uuid) OR ritc.identity_blocked(i,s) THEN RETURN NULL; END IF;
 SELECT u.email INTO email FROM auth.users u WHERE u.id=s::uuid AND u.email_confirmed_at IS NOT NULL FOR SHARE;
 RETURN email;
EXCEPTION WHEN invalid_text_representation THEN RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION ritc.guardian_confirmed_email(uuid,uuid,uuid,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.guardian_confirmed_email(uuid,uuid,uuid,text,text,text) TO ritc_app,ritc_guardian_verifier;
CREATE FUNCTION ritc.identity_has_adult_profile(i text,s text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$ SELECT EXISTS(SELECT 1 FROM ritc.member WHERE issuer=i AND subject=s AND kind='adult') $$;
REVOKE ALL ON FUNCTION ritc.identity_has_adult_profile(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.identity_has_adult_profile(text,text) TO ritc_app;

-- Only the separate verifier connection, after checking the official raw-body
-- signature and current email, may commit provider adulthood evidence.
CREATE FUNCTION ritc.guardian_record_verification(h uuid,a uuid,n text,e text,o text,p uuid,v text,t text,b text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE attempt ritc.guardian_attempt; setup ritc.guardian_enrollment; prior ritc.guardian_provider_event;
BEGIN
 IF h::text IS DISTINCT FROM current_setting('app.household_id',true) THEN RETURN 'unavailable'; END IF;
 PERFORM 1 FROM ritc.household WHERE household_id=h FOR UPDATE;
 SELECT * INTO attempt FROM ritc.guardian_attempt WHERE household_id=h AND attempt_id=a;
 IF NOT FOUND THEN RETURN 'unavailable'; END IF;
 SELECT * INTO setup FROM ritc.guardian_enrollment WHERE household_id=h AND enrollment_id=attempt.enrollment_id;
 IF attempt.nonce_hash<>n OR attempt.email_digest<>e OR attempt.organization_id<>o OR attempt.product_id IS DISTINCT FROM p OR attempt.environment<>v THEN RETURN 'unavailable'; END IF;
 SELECT * INTO prior FROM ritc.guardian_provider_event WHERE household_id=h AND attempt_id=a;
 IF FOUND THEN
  IF prior.transaction_id=t AND prior.event_digest=b THEN RETURN 'duplicate'; END IF;
  RETURN 'changed_event';
 END IF;
 IF setup.state NOT IN('verification_pending','verification_uncertain') OR setup.expires_at<=clock_timestamp() OR attempt.expires_at<=clock_timestamp()
 OR ritc.guardian_confirmed_email(h,setup.guardian_id,setup.guardian_device_id,setup.guardian_issuer,setup.guardian_subject,setup.guardian_session) IS NULL THEN RETURN 'ended'; END IF;
 INSERT INTO ritc.guardian_provider_event(household_id,attempt_id,transaction_id,event_digest) VALUES(h,a,t,b);
 UPDATE ritc.guardian_enrollment SET state='verified',verified_at=clock_timestamp(),revision=revision+1 WHERE household_id=h AND enrollment_id=setup.enrollment_id;
 RETURN 'verified';
END $$;
REVOKE ALL ON FUNCTION ritc.guardian_record_verification(uuid,uuid,text,text,text,uuid,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.guardian_record_verification(uuid,uuid,text,text,text,uuid,text,text,text) TO ritc_guardian_verifier;

-- Called after explicit permission, child authentication and guardian comparison
-- of the child's device-generated pairing code. It cannot create adult authority.
CREATE FUNCTION ritc.guardian_finish(h uuid,c uuid,i text,s text,p text,k text,eh text,d uuid,dh text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE claim ritc.guardian_child_claim; invitation ritc.guardian_child_invitation; setup ritc.guardian_enrollment; child ritc.member; fresh_consent uuid;
BEGIN
 IF h::text IS DISTINCT FROM current_setting('app.household_id',true) THEN RETURN NULL; END IF;
 PERFORM 1 FROM ritc.household WHERE household_id=h FOR UPDATE;
 SELECT * INTO claim FROM ritc.guardian_child_claim WHERE household_id=h AND claim_id=c;
 IF NOT FOUND OR claim.issuer<>i OR claim.subject<>s OR claim.session_id<>p OR claim.pairing_hash<>k OR claim.revoked_at IS NOT NULL OR claim.expires_at<=clock_timestamp() THEN RETURN NULL; END IF;
 SELECT * INTO invitation FROM ritc.guardian_child_invitation WHERE household_id=h AND invite_id=claim.invite_id;
 SELECT * INTO setup FROM ritc.guardian_enrollment WHERE household_id=h AND enrollment_id=invitation.enrollment_id;
 IF setup.state<>'child_approved' OR setup.claim_id<>c OR setup.consented_at IS NULL OR setup.child_alias IS NULL OR setup.expires_at<=clock_timestamp()
 OR claim.approved_at IS NULL OR claim.finished_at IS NOT NULL OR invitation.revoked_at IS NOT NULL OR invitation.consumed_at IS NOT NULL OR invitation.expires_at<=clock_timestamp()
 OR NOT EXISTS(SELECT 1 FROM ritc.guardian_attempt a JOIN ritc.guardian_provider_event e USING(household_id,attempt_id) WHERE a.household_id=h AND a.enrollment_id=setup.enrollment_id AND a.email_digest=eh)
 OR ritc.guardian_confirmed_email(h,setup.guardian_id,setup.guardian_device_id,setup.guardian_issuer,setup.guardian_subject,setup.guardian_session) IS NULL
 OR NOT ritc.provider_session_live(p::uuid,s::uuid) OR ritc.identity_blocked(i,s) OR ritc.identity_has_adult_profile(i,s) THEN RETURN NULL; END IF;
 SELECT * INTO child FROM ritc.member WHERE household_id=h AND member_id=setup.child_id;
 IF FOUND AND (child.kind<>'child' OR child.issuer<>i OR child.subject<>s OR child.erased_at IS NOT NULL) THEN RETURN NULL; END IF;
 IF child.member_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM ritc.guardian_relationship WHERE household_id=h AND child_id=child.member_id AND guardian_id=setup.guardian_id AND revoked_at IS NULL) THEN RETURN NULL; END IF;
 IF (child.member_id IS NULL OR child.state<>'active') AND NOT EXISTS(SELECT 1 FROM ritc.member WHERE household_id=h AND member_id=setup.guardian_id AND kind='adult' AND state='active' AND organizer) THEN RETURN NULL; END IF;
 IF EXISTS(SELECT 1 FROM ritc.member WHERE household_id=h AND issuer=i AND subject=s AND member_id<>setup.child_id) THEN RETURN NULL; END IF;
 IF EXISTS(SELECT 1 FROM ritc.consent WHERE household_id=h AND child_id=setup.child_id AND revoked_at IS NULL) THEN RETURN NULL; END IF;
 INSERT INTO ritc.member(household_id,member_id,issuer,subject,alias,kind,state,organizer,can_contribute)
 VALUES(h,setup.child_id,i,s,setup.child_alias,'child','active',false,true)
 ON CONFLICT(household_id,member_id) DO UPDATE SET state='active',alias=EXCLUDED.alias,organizer=false,can_contribute=true;
 INSERT INTO ritc.guardian_relationship(household_id,child_id,guardian_id,proof_ref) VALUES(h,setup.child_id,setup.guardian_id,'guardian-enrollment:'||setup.enrollment_id::text)
 ON CONFLICT(household_id,child_id,guardian_id) DO UPDATE SET proof_ref=EXCLUDED.proof_ref,revoked_at=NULL;
 fresh_consent=gen_random_uuid();
 INSERT INTO ritc.consent(household_id,consent_id,child_id,guardian_id,notice_version,verification_ref,granted_at)
 VALUES(h,fresh_consent,setup.child_id,setup.guardian_id,setup.notice_version,'guardian-enrollment:'||setup.enrollment_id::text,setup.consented_at);
 INSERT INTO ritc.device(household_id,device_id,member_id,token_hash,session_id,guardian_consent_id) VALUES(h,d,setup.child_id,dh,p,fresh_consent);
 UPDATE ritc.guardian_child_claim SET finished_at=clock_timestamp(),device_id=d,device_hash=dh WHERE household_id=h AND claim_id=c;
 UPDATE ritc.guardian_child_invitation SET consumed_at=clock_timestamp() WHERE household_id=h AND invite_id=claim.invite_id;
 UPDATE ritc.guardian_enrollment SET state='active',consent_id=fresh_consent,revision=revision+1 WHERE household_id=h AND enrollment_id=setup.enrollment_id;
 RETURN setup.child_id;
END $$;
REVOKE ALL ON FUNCTION ritc.guardian_finish(uuid,uuid,text,text,text,text,text,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.guardian_finish(uuid,uuid,text,text,text,text,text,uuid,text) TO ritc_app;

CREATE FUNCTION ritc.guardian_retire_access() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF TG_TABLE_NAME='consent' THEN
  IF TG_OP='DELETE' THEN
   DELETE FROM ritc.guardian_enrollment WHERE household_id=OLD.household_id AND consent_id=OLD.consent_id;
   RETURN OLD;
  ELSIF NEW.revoked_at IS NOT NULL AND OLD.revoked_at IS NULL THEN
   UPDATE ritc.guardian_enrollment SET state='withdrawn',revision=revision+1 WHERE household_id=NEW.household_id AND child_id=NEW.child_id AND state NOT IN('withdrawn','cancelled','expired');
   UPDATE ritc.device SET revoked_at=COALESCE(revoked_at,NEW.revoked_at) WHERE household_id=NEW.household_id AND member_id=NEW.child_id;
   UPDATE ritc.replay_window SET revoked_at=COALESCE(revoked_at,NEW.revoked_at) WHERE household_id=NEW.household_id AND member_id=NEW.child_id;
  END IF;
 ELSIF TG_TABLE_NAME='member' THEN
  IF NEW.erased_at IS NOT NULL AND OLD.erased_at IS NULL THEN
   IF OLD.kind='child' AND OLD.issuer<>'urn:ritc:erased' AND NULLIF(current_setting('app.erasure_job',true),'') IS NOT NULL THEN
    INSERT INTO ritc.identity_erasure(identity_hash,job_id,retain_until) SELECT encode(sha256(convert_to(OLD.issuer||E'\n'||OLD.subject,'utf8')),'hex'),job_id,marker_until FROM ritc.privacy_job WHERE job_id=current_setting('app.erasure_job',true)::uuid ON CONFLICT DO NOTHING;
   END IF;
   DELETE FROM ritc.guardian_enrollment WHERE household_id=NEW.household_id AND (guardian_id=NEW.member_id OR child_id=NEW.member_id);
  ELSIF NEW.state<>'active' THEN
   UPDATE ritc.consent SET revoked_at=clock_timestamp() WHERE household_id=NEW.household_id AND (guardian_id=NEW.member_id OR child_id=NEW.member_id) AND revoked_at IS NULL;
   UPDATE ritc.guardian_enrollment SET state='withdrawn',revision=revision+1 WHERE household_id=NEW.household_id AND (guardian_id=NEW.member_id OR child_id=NEW.member_id) AND state NOT IN('withdrawn','cancelled','expired');
  END IF;
 ELSIF TG_TABLE_NAME='device' AND NEW.revoked_at IS NOT NULL AND OLD.revoked_at IS NULL THEN
  UPDATE ritc.guardian_enrollment SET state='withdrawn',revision=revision+1 WHERE household_id=NEW.household_id AND guardian_device_id=NEW.device_id AND state NOT IN('active','withdrawn','cancelled','expired');
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ritc.guardian_retire_access() FROM PUBLIC;
CREATE TRIGGER guardian_consent_retire AFTER UPDATE OR DELETE ON ritc.consent FOR EACH ROW EXECUTE FUNCTION ritc.guardian_retire_access();
CREATE TRIGGER guardian_member_retire AFTER UPDATE ON ritc.member FOR EACH ROW EXECUTE FUNCTION ritc.guardian_retire_access();
CREATE TRIGGER guardian_device_retire AFTER UPDATE ON ritc.device FOR EACH ROW EXECUTE FUNCTION ritc.guardian_retire_access();

-- Pending child identities cannot self-attest into adult privileges, and erasure
-- also covers a claimed identity which has not yet become a member.
CREATE INDEX guardian_claim_identity ON ritc.guardian_child_claim(issuer,subject);
CREATE OR REPLACE FUNCTION ritc.identity_has_child_profile(identity_issuer text,identity_subject text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT EXISTS(SELECT 1 FROM ritc.member WHERE issuer=identity_issuer AND subject=identity_subject AND kind='child')
 OR EXISTS(SELECT 1 FROM ritc.guardian_child_claim WHERE issuer=identity_issuer AND subject=identity_subject)
$$;
CREATE FUNCTION ritc.guardian_identity_erased() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE target record;
BEGIN
 FOR target IN SELECT DISTINCT c.household_id,i.enrollment_id FROM (SELECT household_id,invite_id,issuer,subject FROM ritc.guardian_child_claim UNION ALL SELECT household_id,invite_id,issuer,subject FROM ritc.guardian_child_signin) c JOIN ritc.guardian_child_invitation i USING(household_id,invite_id)
 WHERE encode(sha256(convert_to(c.issuer||E'\n'||c.subject,'utf8')),'hex')=NEW.identity_hash ORDER BY c.household_id,i.enrollment_id LOOP
  PERFORM 1 FROM ritc.household WHERE household_id=target.household_id FOR UPDATE;
  DELETE FROM ritc.guardian_enrollment WHERE household_id=target.household_id AND enrollment_id=target.enrollment_id;
 END LOOP;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ritc.guardian_identity_erased() FROM PUBLIC;
CREATE TRIGGER guardian_pending_identity_erased AFTER INSERT ON ritc.identity_erasure FOR EACH ROW EXECUTE FUNCTION ritc.guardian_identity_erased();

-- A runtime SQL writer cannot clear withdrawal, reuse a completed generation or
-- clear a consumed/revoked invitation. Fresh consent requires fresh evidence.
CREATE FUNCTION ritc.guardian_setup_transition() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE allowed text[];
BEGIN
 IF (to_jsonb(NEW)-ARRAY['state','revision','child_alias','verified_at','consented_at','consent_id','claim_id','child_email_digest']) IS DISTINCT FROM
    (to_jsonb(OLD)-ARRAY['state','revision','child_alias','verified_at','consented_at','consent_id','claim_id','child_email_digest']) OR NEW.revision<>OLD.revision+1 THEN
  RAISE EXCEPTION 'guardian setup is immutable except a reviewed transition' USING ERRCODE='23514';
 END IF;
 IF OLD.state IN('withdrawn','cancelled','expired') THEN RAISE EXCEPTION 'ended guardian setup requires a fresh flow' USING ERRCODE='23514'; END IF;
 allowed=CASE OLD.state
 WHEN 'awaiting_verification' THEN ARRAY['verification_pending','cancelled','expired','withdrawn']
 WHEN 'verification_pending' THEN ARRAY['verification_uncertain','verified','cancelled','expired','withdrawn']
 WHEN 'verification_uncertain' THEN ARRAY['verified','cancelled','expired','withdrawn']
 WHEN 'verified' THEN ARRAY['consented','cancelled','expired','withdrawn']
 WHEN 'consented' THEN ARRAY['child_claimed','cancelled','expired','withdrawn']
 WHEN 'child_claimed' THEN ARRAY['child_approved','cancelled','expired','withdrawn']
 WHEN 'child_approved' THEN ARRAY['active','cancelled','expired','withdrawn']
 WHEN 'active' THEN ARRAY['withdrawn'] ELSE ARRAY[]::text[] END;
 IF NOT NEW.state=ANY(allowed) OR (OLD.verified_at IS NOT NULL AND NEW.verified_at IS DISTINCT FROM OLD.verified_at)
 OR (OLD.consented_at IS NOT NULL AND NEW.consented_at IS DISTINCT FROM OLD.consented_at)
 OR (OLD.consent_id IS NOT NULL AND NEW.consent_id IS DISTINCT FROM OLD.consent_id)
 OR (OLD.claim_id IS NOT NULL AND NEW.claim_id IS DISTINCT FROM OLD.claim_id)
 OR (OLD.child_alias IS NOT NULL AND NEW.child_alias IS DISTINCT FROM OLD.child_alias)
 OR (OLD.child_email_digest IS NOT NULL AND NEW.child_email_digest IS DISTINCT FROM OLD.child_email_digest) THEN
  RAISE EXCEPTION 'invalid guardian transition' USING ERRCODE='23514';
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ritc.guardian_setup_transition() FROM PUBLIC;
CREATE TRIGGER guardian_setup_transition BEFORE UPDATE ON ritc.guardian_enrollment FOR EACH ROW EXECUTE FUNCTION ritc.guardian_setup_transition();
CREATE FUNCTION ritc.guardian_one_way_stamp() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF TG_TABLE_NAME='guardian_child_invitation' THEN
  IF (OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at) OR (OLD.consumed_at IS NOT NULL AND NEW.consumed_at IS DISTINCT FROM OLD.consumed_at)
  OR (to_jsonb(NEW)-ARRAY['revoked_at','consumed_at']) IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['revoked_at','consumed_at']) THEN RAISE EXCEPTION 'invitation cannot be restored' USING ERRCODE='23514'; END IF;
 ELSE
  IF (OLD.approved_at IS NOT NULL AND NEW.approved_at IS DISTINCT FROM OLD.approved_at) OR (OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at)
  OR (OLD.finished_at IS NOT NULL AND (NEW.finished_at,NEW.device_id,NEW.device_hash) IS DISTINCT FROM (OLD.finished_at,OLD.device_id,OLD.device_hash))
  OR (to_jsonb(NEW)-ARRAY['approved_at','revoked_at','finished_at','device_id','device_hash']) IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['approved_at','revoked_at','finished_at','device_id','device_hash']) THEN RAISE EXCEPTION 'claim cannot be restored' USING ERRCODE='23514'; END IF;
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ritc.guardian_one_way_stamp() FROM PUBLIC;
CREATE TRIGGER guardian_invitation_once BEFORE UPDATE ON ritc.guardian_child_invitation FOR EACH ROW EXECUTE FUNCTION ritc.guardian_one_way_stamp();
CREATE TRIGGER guardian_claim_once BEFORE UPDATE ON ritc.guardian_child_claim FOR EACH ROW EXECUTE FUNCTION ritc.guardian_one_way_stamp();
REVOKE INSERT ON ritc.guardian_child_invitation,ritc.guardian_child_claim FROM ritc_app;
GRANT INSERT(household_id,invite_id,enrollment_id,secret_hash,expires_at) ON ritc.guardian_child_invitation TO ritc_app;
GRANT INSERT(household_id,claim_id,invite_id,issuer,subject,session_id,pairing_hash,expires_at) ON ritc.guardian_child_claim TO ritc_app;

-- Negative authority belongs to the provider principal's actual lifetime, not
-- an arbitrary retention timer. Erasing a profile must never turn a still-live
-- child's provider account into an adult. No email, alias or documents here.
-- This private table has no runtime SELECT/write grants. Provider removal alone
-- cascades the classification; this migration never deletes provider accounts.
CREATE TABLE ritc.guardian_child_principal (
 provider_user uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 identity_hash text NOT NULL PRIMARY KEY CHECK(identity_hash ~ '^[0-9a-f]{64}$')
);
ALTER TABLE ritc.guardian_child_principal ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.guardian_child_principal FORCE ROW LEVEL SECURITY;
INSERT INTO ritc.guardian_child_principal(provider_user,identity_hash)
 SELECT u.id,encode(sha256(convert_to(m.issuer||E'\n'||m.subject,'utf8')),'hex') FROM ritc.member m JOIN auth.users u ON u.id::text=m.subject
 WHERE m.kind='child' AND m.issuer<>'urn:ritc:erased' ON CONFLICT DO NOTHING;
CREATE FUNCTION ritc.guardian_classify_claim() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NOT ritc.provider_session_live(NEW.session_id::uuid,NEW.subject::uuid) OR ritc.identity_has_adult_profile(NEW.issuer,NEW.subject) OR ritc.identity_blocked(NEW.issuer,NEW.subject) THEN
  RAISE EXCEPTION 'live child principal required' USING ERRCODE='23514';
 END IF;
 INSERT INTO ritc.guardian_child_principal(provider_user,identity_hash) VALUES(NEW.subject::uuid,encode(sha256(convert_to(NEW.issuer||E'\n'||NEW.subject,'utf8')),'hex')) ON CONFLICT DO NOTHING;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ritc.guardian_classify_claim() FROM PUBLIC;
CREATE TRIGGER guardian_classify_claim BEFORE INSERT ON ritc.guardian_child_claim FOR EACH ROW EXECUTE FUNCTION ritc.guardian_classify_claim();
CREATE OR REPLACE FUNCTION ritc.identity_has_child_profile(identity_issuer text,identity_subject text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT EXISTS(SELECT 1 FROM ritc.guardian_child_principal WHERE identity_hash=encode(sha256(convert_to(identity_issuer||E'\n'||identity_subject,'utf8')),'hex'))
 OR EXISTS(SELECT 1 FROM ritc.member WHERE issuer=identity_issuer AND subject=identity_subject AND kind='child')
 OR EXISTS(SELECT 1 FROM ritc.guardian_child_claim WHERE issuer=identity_issuer AND subject=identity_subject)
$$;

-- Ordinary runtime writers cannot mint a paired child device or restore a lost
-- credential using an existing consent generation. Only the table-owning narrow
-- SECURITY DEFINER finalizer/eraser can create or replace child credentials.
CREATE FUNCTION ritc.guardian_child_device_guard() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE owner_name text; child boolean;
BEGIN
 SELECT pg_get_userbyid(c.relowner) INTO owner_name FROM pg_class c WHERE c.oid='ritc.device'::regclass;
 SELECT kind='child' INTO child FROM ritc.member WHERE household_id=NEW.household_id AND member_id=NEW.member_id;
 IF TG_OP='INSERT' THEN
  IF child AND current_user<>owner_name THEN RAISE EXCEPTION 'child device requires guardian finalization' USING ERRCODE='23514'; END IF;
 ELSE
  IF OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at THEN RAISE EXCEPTION 'device cannot be restored' USING ERRCODE='23514'; END IF;
  IF current_user<>owner_name AND (to_jsonb(NEW)-'revoked_at') IS DISTINCT FROM (to_jsonb(OLD)-'revoked_at') THEN RAISE EXCEPTION 'device credentials are immutable' USING ERRCODE='23514'; END IF;
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ritc.guardian_child_device_guard() FROM PUBLIC;
CREATE TRIGGER guardian_child_device_guard BEFORE INSERT OR UPDATE ON ritc.device FOR EACH ROW EXECUTE FUNCTION ritc.guardian_child_device_guard();

-- Guardian permission covers the intended child's actual sign-in before asking
-- the identity provider to create an account or send OTP. Only a keyed digest of
-- the address is part of enrollment; the BFF already encrypts temporary OTP mail.
ALTER TABLE ritc.guardian_enrollment ADD COLUMN child_email_digest text CHECK(child_email_digest ~ '^[0-9a-f]{64}$');
GRANT UPDATE(child_email_digest) ON ritc.guardian_enrollment TO ritc_app;
ALTER TABLE ritc.browser_auth ADD COLUMN guardian_household_id uuid;
ALTER TABLE ritc.browser_auth ADD COLUMN guardian_invite_id uuid;
ALTER TABLE ritc.browser_auth ADD COLUMN guardian_signin_started_at timestamptz;
ALTER TABLE ritc.browser_auth ADD CONSTRAINT guardian_auth_binding CHECK((guardian_household_id IS NULL)=(guardian_invite_id IS NULL));
CREATE TABLE ritc.guardian_child_signin (
 household_id uuid NOT NULL,invite_id uuid NOT NULL,issuer text NOT NULL,subject text NOT NULL,session_id text NOT NULL,expires_at timestamptz NOT NULL,
 PRIMARY KEY(household_id,invite_id,issuer,subject,session_id),
 FOREIGN KEY(household_id,invite_id) REFERENCES ritc.guardian_child_invitation ON DELETE CASCADE
);
ALTER TABLE ritc.guardian_child_signin ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.guardian_child_signin FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON ritc.guardian_child_signin USING(household_id::text=(SELECT current_setting('app.household_id',true))) WITH CHECK(household_id::text=(SELECT current_setting('app.household_id',true)));
GRANT SELECT ON ritc.guardian_child_signin TO ritc_app;
CREATE TRIGGER guardian_classify_signin BEFORE INSERT ON ritc.guardian_child_signin FOR EACH ROW EXECUTE FUNCTION ritc.guardian_classify_claim();
CREATE FUNCTION ritc.guardian_child_confirmed_email(h uuid,inv uuid,i text,s text,p text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE result text;
BEGIN
 IF h::text IS DISTINCT FROM current_setting('app.household_id',true) OR NOT ritc.provider_session_live(p::uuid,s::uuid) OR ritc.identity_blocked(i,s) OR ritc.identity_has_adult_profile(i,s) THEN RETURN NULL; END IF;
 IF NOT EXISTS(SELECT 1 FROM ritc.guardian_child_invitation v JOIN ritc.guardian_enrollment e USING(household_id,enrollment_id)
 WHERE v.household_id=h AND v.invite_id=inv AND v.revoked_at IS NULL AND v.consumed_at IS NULL AND v.expires_at>clock_timestamp() AND e.state IN('consented','child_claimed','child_approved') AND e.child_email_digest IS NOT NULL AND e.expires_at>clock_timestamp()
 AND ritc.guardian_confirmed_email(h,e.guardian_id,e.guardian_device_id,e.guardian_issuer,e.guardian_subject,e.guardian_session) IS NOT NULL) THEN RETURN NULL; END IF;
 SELECT email INTO result FROM auth.users WHERE id=s::uuid AND email_confirmed_at IS NOT NULL FOR SHARE;
 RETURN result;
EXCEPTION WHEN invalid_text_representation THEN RETURN NULL;
END $$;
CREATE FUNCTION ritc.guardian_admit_signin(h uuid,inv uuid,i text,s text,p text,email_hash text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE setup ritc.guardian_enrollment;
BEGIN
 IF ritc.guardian_child_confirmed_email(h,inv,i,s,p) IS NULL THEN RETURN false; END IF;
 SELECT e.* INTO setup FROM ritc.guardian_enrollment e JOIN ritc.guardian_child_invitation v USING(household_id,enrollment_id) WHERE v.household_id=h AND v.invite_id=inv;
 IF setup.child_email_digest IS DISTINCT FROM email_hash THEN RETURN false; END IF;
 INSERT INTO ritc.guardian_child_signin(household_id,invite_id,issuer,subject,session_id,expires_at) VALUES(h,inv,i,s,p,setup.expires_at) ON CONFLICT DO NOTHING;
 RETURN true;
END $$;
REVOKE ALL ON FUNCTION ritc.guardian_child_confirmed_email(uuid,uuid,text,text,text),ritc.guardian_admit_signin(uuid,uuid,text,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.guardian_child_confirmed_email(uuid,uuid,text,text,text),ritc.guardian_admit_signin(uuid,uuid,text,text,text,text) TO ritc_app;
CREATE TABLE ritc.guardian_native_challenge (
 household_id uuid NOT NULL,challenge_id uuid NOT NULL,invite_id uuid NOT NULL,client_key uuid NOT NULL,
 secret_hash text NOT NULL CHECK(secret_hash ~ '^[0-9a-f]{64}$'),payload_digest text NOT NULL,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),expires_at timestamptz NOT NULL,
 issuer text,subject text,session_id text,admit_key uuid,
 PRIMARY KEY(household_id,challenge_id),UNIQUE(household_id,invite_id,client_key),UNIQUE(household_id,invite_id),
 FOREIGN KEY(household_id,invite_id) REFERENCES ritc.guardian_child_invitation ON DELETE CASCADE
);
ALTER TABLE ritc.guardian_native_challenge ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.guardian_native_challenge FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON ritc.guardian_native_challenge USING(household_id::text=(SELECT current_setting('app.household_id',true))) WITH CHECK(household_id::text=(SELECT current_setting('app.household_id',true)));
GRANT SELECT,INSERT ON ritc.guardian_native_challenge TO ritc_app;
GRANT UPDATE(issuer,subject,session_id,admit_key) ON ritc.guardian_native_challenge TO ritc_app;

-- Scheduled housekeeping is technical expiry plus explicitly configured evidence
-- policy. No legal retention duration is guessed, and no provider calls occur.
CREATE INDEX guardian_setup_expiry ON ritc.guardian_enrollment(expires_at);
CREATE FUNCTION ritc.guardian_housekeeping(batch_size integer,pending_hours integer DEFAULT NULL,evidence_days integer DEFAULT NULL) RETURNS TABLE(expired integer,purged integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE candidate record;setup ritc.guardian_enrollment;n integer:=greatest(1,least(batch_size,100));
BEGIN
 IF pending_hours IS NOT NULL AND pending_hours NOT BETWEEN 1 AND 8760 OR evidence_days IS NOT NULL AND evidence_days NOT BETWEEN 1 AND 3650 THEN RAISE EXCEPTION 'explicit guardian retention policy required'; END IF;
 expired=0;purged=0;
 FOR candidate IN SELECT household_id,enrollment_id FROM ritc.guardian_enrollment WHERE (expires_at<=clock_timestamp() AND state NOT IN('active','expired','cancelled','withdrawn')) OR
  (state IN('expired','cancelled','withdrawn') AND ((consent_id IS NULL AND pending_hours IS NOT NULL AND expires_at+make_interval(hours=>pending_hours)<=clock_timestamp()) OR
   (consent_id IS NOT NULL AND evidence_days IS NOT NULL AND EXISTS(SELECT 1 FROM ritc.consent c WHERE c.household_id=guardian_enrollment.household_id AND c.consent_id=guardian_enrollment.consent_id AND c.revoked_at+make_interval(days=>evidence_days)<=clock_timestamp())))) ORDER BY expires_at,household_id,enrollment_id LIMIT n LOOP
  BEGIN PERFORM 1 FROM ritc.household WHERE household_id=candidate.household_id FOR UPDATE NOWAIT; EXCEPTION WHEN lock_not_available THEN CONTINUE; END;
  SELECT * INTO setup FROM ritc.guardian_enrollment WHERE household_id=candidate.household_id AND enrollment_id=candidate.enrollment_id;
  IF NOT FOUND THEN CONTINUE; END IF;
  IF setup.expires_at<=clock_timestamp() AND setup.state NOT IN('active','expired','cancelled','withdrawn') THEN
   UPDATE ritc.guardian_enrollment SET state='expired',revision=revision+1 WHERE household_id=setup.household_id AND enrollment_id=setup.enrollment_id;
   UPDATE ritc.guardian_child_invitation SET revoked_at=COALESCE(revoked_at,clock_timestamp()) WHERE household_id=setup.household_id AND enrollment_id=setup.enrollment_id;
   UPDATE ritc.guardian_child_claim SET revoked_at=COALESCE(revoked_at,clock_timestamp()) WHERE household_id=setup.household_id AND invite_id IN(SELECT invite_id FROM ritc.guardian_child_invitation WHERE household_id=setup.household_id AND enrollment_id=setup.enrollment_id);
   UPDATE ritc.browser_auth SET email_cipher=NULL,revoked_at=COALESCE(revoked_at,clock_timestamp()) WHERE phase='challenge' AND guardian_household_id=setup.household_id AND guardian_invite_id IN(SELECT invite_id FROM ritc.guardian_child_invitation WHERE household_id=setup.household_id AND enrollment_id=setup.enrollment_id);
   expired=expired+1;setup.state='expired';
  END IF;
  IF setup.state IN('expired','cancelled','withdrawn') AND
   ((setup.consent_id IS NULL AND pending_hours IS NOT NULL AND setup.expires_at+make_interval(hours=>pending_hours)<=clock_timestamp()) OR
    (setup.consent_id IS NOT NULL AND evidence_days IS NOT NULL AND EXISTS(SELECT 1 FROM ritc.consent WHERE household_id=setup.household_id AND consent_id=setup.consent_id AND revoked_at+make_interval(days=>evidence_days)<=clock_timestamp()))) THEN
   -- BFF challenge identifiers are staged access, never authority on restore.
   UPDATE ritc.browser_auth SET email_cipher=NULL,guardian_household_id=NULL,guardian_invite_id=NULL,guardian_signin_started_at=NULL WHERE phase='challenge' AND guardian_household_id=setup.household_id AND guardian_invite_id IN(SELECT invite_id FROM ritc.guardian_child_invitation WHERE household_id=setup.household_id AND enrollment_id=setup.enrollment_id);
   DELETE FROM ritc.guardian_enrollment WHERE household_id=setup.household_id AND enrollment_id=setup.enrollment_id;purged=purged+1;
  END IF;
 END LOOP;
 RETURN NEXT;
END $$;
REVOKE ALL ON FUNCTION ritc.guardian_housekeeping(integer,integer,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.guardian_housekeeping(integer,integer,integer) TO ritc_worker;

-- Retire challenge material immediately when permission ends. This lock order is
-- household -> browser_auth; BFF household hooks run outside browser transactions.
CREATE FUNCTION ritc.guardian_retire_setup_challenges() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE h uuid;enrollment uuid;
BEGIN
 h=OLD.household_id;enrollment=OLD.enrollment_id;
 UPDATE ritc.browser_auth SET email_cipher=NULL,revoked_at=COALESCE(revoked_at,clock_timestamp()) WHERE phase='challenge' AND guardian_household_id=h AND guardian_invite_id IN(SELECT invite_id FROM ritc.guardian_child_invitation WHERE household_id=h AND enrollment_id=enrollment);
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 UPDATE ritc.guardian_child_invitation SET revoked_at=COALESCE(revoked_at,clock_timestamp()) WHERE household_id=h AND enrollment_id=enrollment;
 UPDATE ritc.guardian_child_claim SET revoked_at=COALESCE(revoked_at,clock_timestamp()) WHERE household_id=h AND invite_id IN(SELECT invite_id FROM ritc.guardian_child_invitation WHERE household_id=h AND enrollment_id=enrollment);
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ritc.guardian_retire_setup_challenges() FROM PUBLIC;
CREATE TRIGGER guardian_setup_retire_challenges AFTER UPDATE ON ritc.guardian_enrollment FOR EACH ROW WHEN(NEW.state IN('cancelled','expired','withdrawn') AND OLD.state IS DISTINCT FROM NEW.state) EXECUTE FUNCTION ritc.guardian_retire_setup_challenges();
CREATE TRIGGER guardian_setup_erase_challenges BEFORE DELETE ON ritc.guardian_enrollment FOR EACH ROW EXECUTE FUNCTION ritc.guardian_retire_setup_challenges();

-- The ordinary application writer cannot authenticate a provider principal by
-- echoing a readable email digest. Only the distinct verification connection,
-- after real JWT/email/OTP checks, may admit or activate a child.
REVOKE EXECUTE ON FUNCTION ritc.guardian_admit_signin(uuid,uuid,text,text,text,text),ritc.guardian_finish(uuid,uuid,text,text,text,text,text,uuid,text) FROM ritc_app;
CREATE FUNCTION ritc.guardian_admit_child_verified(h uuid,inv uuid,i text,s text,p text,current_email text,email_hash text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE guardian record;
BEGIN
 IF h::text IS DISTINCT FROM current_setting('app.household_id',true) OR NOT ritc.guardian_lock_identity(i,s) THEN RETURN false; END IF;
 SELECT e.guardian_issuer,e.guardian_subject INTO guardian FROM ritc.guardian_enrollment e JOIN ritc.guardian_child_invitation v USING(household_id,enrollment_id) WHERE v.household_id=h AND v.invite_id=inv;
 IF NOT FOUND OR NOT ritc.guardian_lock_identity(guardian.guardian_issuer,guardian.guardian_subject) THEN RETURN false; END IF;
 PERFORM 1 FROM ritc.household WHERE household_id=h FOR UPDATE;
 IF ritc.guardian_child_confirmed_email(h,inv,i,s,p) IS DISTINCT FROM current_email OR current_email IS NULL THEN RETURN false; END IF;
 RETURN ritc.guardian_admit_signin(h,inv,i,s,p,email_hash);
END $$;
CREATE FUNCTION ritc.guardian_finish_verified(h uuid,c uuid,i text,s text,p text,k text,eh text,d uuid,dh text,operation_key uuid,payload text,guardian_email text,child_email text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE claim ritc.guardian_child_claim;invitation ritc.guardian_child_invitation;setup ritc.guardian_enrollment;prior ritc.guardian_intent;child uuid;receipt jsonb;actual_child_email text;
BEGIN
 IF h::text IS DISTINCT FROM current_setting('app.household_id',true) OR NOT ritc.guardian_lock_identity(i,s) OR NOT ritc.provider_session_live(p::uuid,s::uuid) THEN RETURN NULL; END IF;
 SELECT e.* INTO setup FROM ritc.guardian_enrollment e JOIN ritc.guardian_child_invitation v USING(household_id,enrollment_id) JOIN ritc.guardian_child_claim x USING(household_id,invite_id) WHERE x.household_id=h AND x.claim_id=c;
 IF NOT FOUND OR NOT ritc.guardian_lock_identity(setup.guardian_issuer,setup.guardian_subject) THEN RETURN NULL; END IF;
 PERFORM 1 FROM ritc.household WHERE household_id=h FOR UPDATE;
 SELECT * INTO claim FROM ritc.guardian_child_claim WHERE household_id=h AND claim_id=c AND issuer=i AND subject=s AND session_id=p AND pairing_hash=k;
 IF NOT FOUND THEN RETURN NULL; END IF;
 SELECT * INTO invitation FROM ritc.guardian_child_invitation WHERE household_id=h AND invite_id=claim.invite_id;
 SELECT * INTO setup FROM ritc.guardian_enrollment WHERE household_id=h AND enrollment_id=invitation.enrollment_id;
 SELECT * INTO prior FROM ritc.guardian_intent x WHERE x.household_id=h AND x.issuer=i AND x.subject=s AND x.client_key=operation_key;
 IF FOUND THEN
  IF prior.session_id<>p OR prior.kind<>'finish' OR prior.payload_digest<>payload OR prior.enrollment_id<>setup.enrollment_id OR setup.state<>'active' THEN RETURN NULL; END IF;
  IF NOT EXISTS(SELECT 1 FROM ritc.device v JOIN ritc.consent n ON n.household_id=v.household_id AND n.consent_id=v.guardian_consent_id
   WHERE v.household_id=h AND v.device_id=claim.device_id AND v.member_id=setup.child_id AND v.session_id=p AND v.token_hash=dh AND v.revoked_at IS NULL AND n.revoked_at IS NULL) THEN RETURN NULL; END IF;
  RETURN prior.response;
 END IF;
 IF NOT EXISTS(SELECT 1 FROM ritc.guardian_child_signin a WHERE a.household_id=h AND a.invite_id=claim.invite_id AND a.issuer=i AND a.subject=s AND a.session_id=p AND a.expires_at>clock_timestamp()) THEN RETURN NULL; END IF;
 SELECT email INTO actual_child_email FROM auth.users WHERE id=s::uuid AND email_confirmed_at IS NOT NULL FOR SHARE;
 IF actual_child_email IS DISTINCT FROM child_email OR child_email IS NULL OR guardian_email IS NULL OR
  ritc.guardian_confirmed_email(h,setup.guardian_id,setup.guardian_device_id,setup.guardian_issuer,setup.guardian_subject,setup.guardian_session) IS DISTINCT FROM guardian_email THEN RETURN NULL; END IF;
 child=ritc.guardian_finish(h,c,i,s,p,k,eh,d,dh);IF child IS NULL THEN RETURN NULL; END IF;
 receipt=jsonb_build_object('householdId',h,'memberId',child,'role','contributor','deviceId',d);
 INSERT INTO ritc.guardian_intent(household_id,issuer,subject,session_id,client_key,enrollment_id,kind,payload_digest,response) VALUES(h,i,s,p,operation_key,setup.enrollment_id,'finish',payload,receipt);
 RETURN receipt;
END $$;
REVOKE ALL ON FUNCTION ritc.guardian_admit_child_verified(uuid,uuid,text,text,text,text,text),ritc.guardian_finish_verified(uuid,uuid,text,text,text,text,text,uuid,text,uuid,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.guardian_admit_child_verified(uuid,uuid,text,text,text,text,text),ritc.guardian_finish_verified(uuid,uuid,text,text,text,text,text,uuid,text,uuid,text,text,text) TO ritc_guardian_verifier;

-- Privileged proof/admission finalization outlives the application preparation
-- transaction. Keep the same nonblocking identity erasure fence inside it.
CREATE FUNCTION ritc.guardian_lock_identity(i text,s text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NOT pg_try_advisory_xact_lock_shared(hashtextextended(encode(sha256(convert_to(i||E'\n'||s,'utf8')),'hex'),0)) THEN RETURN false; END IF;
 RETURN NOT ritc.identity_blocked(i,s);
END $$;
REVOKE ALL ON FUNCTION ritc.guardian_lock_identity(text,text) FROM PUBLIC;

-- A retained native challenge chooses one exact provider session atomically with
-- admission, so simultaneous admits cannot leave an extra admitted session.
REVOKE UPDATE ON ritc.guardian_native_challenge FROM ritc_app;
CREATE FUNCTION ritc.guardian_admit_native_verified(h uuid,challenge uuid,i text,s text,p text,current_email text,email_hash text,challenge_hash text,operation_key uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE requested ritc.guardian_native_challenge;guardian record;
BEGIN
 IF h::text IS DISTINCT FROM current_setting('app.household_id',true) OR NOT ritc.guardian_lock_identity(i,s) THEN RETURN false; END IF;
 SELECT e.guardian_issuer,e.guardian_subject INTO guardian FROM ritc.guardian_native_challenge c JOIN ritc.guardian_child_invitation v USING(household_id,invite_id) JOIN ritc.guardian_enrollment e USING(household_id,enrollment_id) WHERE c.household_id=h AND c.challenge_id=challenge;
 IF NOT FOUND OR NOT ritc.guardian_lock_identity(guardian.guardian_issuer,guardian.guardian_subject) THEN RETURN false; END IF;
 PERFORM 1 FROM ritc.household WHERE household_id=h FOR UPDATE;
 SELECT * INTO requested FROM ritc.guardian_native_challenge WHERE household_id=h AND challenge_id=challenge AND secret_hash=challenge_hash AND expires_at>clock_timestamp() FOR UPDATE;
 IF NOT FOUND OR (requested.subject IS NOT NULL AND (requested.issuer,requested.subject,requested.session_id,requested.admit_key) IS DISTINCT FROM (i,s,p,operation_key)) THEN RETURN false; END IF;
 IF NOT ritc.guardian_admit_child_verified(h,requested.invite_id,i,s,p,current_email,email_hash) THEN RETURN false; END IF;
 UPDATE ritc.guardian_native_challenge SET issuer=i,subject=s,session_id=p,admit_key=operation_key WHERE household_id=h AND challenge_id=challenge;
 RETURN true;
END $$;
REVOKE ALL ON FUNCTION ritc.guardian_admit_native_verified(uuid,uuid,text,text,text,text,text,text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.guardian_admit_native_verified(uuid,uuid,text,text,text,text,text,text,uuid) TO ritc_guardian_verifier;
-- Column grants are independent of table-level privileges in PostgreSQL.
REVOKE UPDATE(issuer,subject,session_id,admit_key) ON ritc.guardian_native_challenge FROM ritc_app;
REVOKE INSERT ON ritc.guardian_native_challenge FROM ritc_app;
GRANT INSERT(household_id,challenge_id,invite_id,client_key,secret_hash,payload_digest,expires_at) ON ritc.guardian_native_challenge TO ritc_app;
