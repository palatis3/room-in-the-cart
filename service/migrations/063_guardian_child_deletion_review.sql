-- Only authenticated provider evidence plus a verifier-admitted child sign-in
-- identifies an account. An invitation, typed address or pending slot alone does not.
CREATE VIEW ritc.guardian_deletion_admission AS
 SELECT DISTINCT e.household_id,e.enrollment_id,e.guardian_id,e.guardian_issuer,e.guardian_subject,
   e.child_id,e.child_alias,e.child_email_digest,a.email_digest AS guardian_email_digest,
   s.issuer,s.subject
 FROM ritc.guardian_enrollment e
 JOIN ritc.guardian_attempt a USING(household_id,enrollment_id)
 JOIN ritc.guardian_provider_event p USING(household_id,attempt_id)
 JOIN ritc.guardian_child_invitation v USING(household_id,enrollment_id)
 JOIN ritc.guardian_child_signin s USING(household_id,invite_id)
 WHERE e.verified_at IS NOT NULL AND e.consented_at IS NOT NULL
   AND e.declaration='parent_or_legal_guardian' AND e.child_alias IS NOT NULL
   AND e.child_email_digest IS NOT NULL;
REVOKE ALL ON ritc.guardian_deletion_admission FROM PUBLIC,ritc_app,ritc_worker,ritc_guardian_verifier;
CREATE INDEX guardian_deletion_signin_subject ON ritc.guardian_child_signin(subject,household_id,invite_id);

-- A review replaces the previous review for this enrollment. It is bounded by
-- the enrollment's existing retention policy, and cascades on account erasure.
CREATE TABLE ritc.guardian_child_deletion_review (
 household_id uuid NOT NULL, enrollment_id uuid NOT NULL, review_id uuid NOT NULL UNIQUE,
 device_id uuid NOT NULL, session_id uuid NOT NULL, target_subject text NOT NULL,authority_digest text NOT NULL,
 guardian_email_hash text NOT NULL, child_email_hash text NOT NULL, expires_at timestamptz NOT NULL,
 PRIMARY KEY(household_id,enrollment_id),
 FOREIGN KEY(household_id,enrollment_id) REFERENCES ritc.guardian_enrollment ON DELETE CASCADE
);
CREATE INDEX guardian_child_deletion_review_expiry ON ritc.guardian_child_deletion_review(expires_at);
ALTER TABLE ritc.guardian_child_deletion_review ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.guardian_child_deletion_review FORCE ROW LEVEL SECURITY;
REVOKE ALL ON ritc.guardian_child_deletion_review FROM PUBLIC,ritc_app,ritc_worker,ritc_guardian_verifier;
DO $$ BEGIN
 EXECUTE format('CREATE POLICY owner_scope ON ritc.guardian_child_deletion_review TO %I USING(true) WITH CHECK(true)',current_user);
END $$;

-- Private account-wide check, repeated under the acceptance identity and household
-- locks. No caller chooses the provider UUID. Never disclose any other household.
CREATE FUNCTION ritc.guardian_deletion_subject(i text,s text,p uuid,h uuid,e uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE target text; guardian_member uuid;
BEGIN
 IF NOT ritc.provider_session_live(p,s::uuid) OR ritc.identity_blocked(i,s) THEN RETURN NULL; END IF;
 SELECT a.subject,a.guardian_id INTO target,guardian_member FROM ritc.guardian_deletion_admission a
 JOIN ritc.member g ON g.household_id=a.household_id AND g.member_id=a.guardian_id
 WHERE a.household_id=h AND a.enrollment_id=e AND a.issuer=i AND a.guardian_issuer=i AND a.guardian_subject=s
   AND g.kind='adult' AND g.state='active' AND g.erased_at IS NULL AND g.issuer=i AND g.subject=s
   AND (g.organizer OR EXISTS(SELECT 1 FROM ritc.member m WHERE m.issuer=i AND m.subject=a.subject AND m.household_id=h))
   AND NOT EXISTS(SELECT 1 FROM ritc.member m WHERE m.household_id=h AND m.member_id=a.child_id AND
       (m.kind<>'child' OR (m.issuer,m.subject) IS DISTINCT FROM (i,a.subject)));
 IF target IS NULL OR target=s OR ritc.identity_blocked(i,target) OR NOT ritc.identity_has_child_profile(i,target)
   OR NOT EXISTS(SELECT 1 FROM auth.users WHERE id=target::uuid AND email_confirmed_at IS NOT NULL)
   OR EXISTS(SELECT 1 FROM ritc.guardian_deletion_admission a WHERE a.household_id=h AND a.enrollment_id=e
             AND (a.issuer,a.subject) IS DISTINCT FROM (i,target))
   OR EXISTS(SELECT 1 FROM ritc.guardian_deletion_admission a WHERE a.subject=target AND
             (a.issuer,a.guardian_issuer,a.guardian_subject) IS DISTINCT FROM (i,i,s))
   OR EXISTS(SELECT 1 FROM ritc.household_creation c WHERE c.subject=target)
   OR EXISTS(SELECT 1 FROM ritc.guardian_enrollment g WHERE g.guardian_subject=target) THEN RETURN NULL; END IF;
 -- Each historical or current membership must be a child profile controlled by
 -- this same verified guardian. Every extant device must have been child-paired.
 IF EXISTS(SELECT 1 FROM ritc.member m WHERE m.subject=target AND (
   m.kind<>'child' OR m.issuer<>i OR m.organizer OR m.erased_at IS NOT NULL OR
   NOT EXISTS(SELECT 1 FROM ritc.guardian_relationship r JOIN ritc.member g
      ON g.household_id=r.household_id AND g.member_id=r.guardian_id
     JOIN ritc.guardian_deletion_admission a ON a.household_id=m.household_id AND a.guardian_id=g.member_id
     WHERE r.household_id=m.household_id AND r.child_id=m.member_id AND r.revoked_at IS NULL
       AND g.issuer=i AND g.subject=s AND g.kind='adult' AND g.state='active' AND g.erased_at IS NULL
       AND a.issuer=i AND a.subject=target AND a.guardian_issuer=i AND a.guardian_subject=s) OR
   EXISTS(SELECT 1 FROM ritc.guardian_relationship r JOIN ritc.member g
      ON g.household_id=r.household_id AND g.member_id=r.guardian_id
     WHERE r.household_id=m.household_id AND r.child_id=m.member_id AND r.revoked_at IS NULL
       AND (g.issuer,g.subject) IS DISTINCT FROM (i,s)) OR
   EXISTS(SELECT 1 FROM ritc.device d WHERE d.household_id=m.household_id AND d.member_id=m.member_id AND NOT EXISTS(
     SELECT 1 FROM ritc.consent c JOIN ritc.member g ON g.household_id=c.household_id AND g.member_id=c.guardian_id
     WHERE c.household_id=d.household_id AND c.consent_id=d.guardian_consent_id AND c.child_id=m.member_id AND g.issuer=i AND g.subject=s)) OR
   EXISTS(SELECT 1 FROM ritc.shop_authority a WHERE a.household_id=m.household_id AND a.member_id=m.member_id) OR
   EXISTS(SELECT 1 FROM ritc.billing_account b WHERE b.household_id=m.household_id AND b.purchaser_id=m.member_id)
 )) THEN RETURN NULL; END IF;
 RETURN target;
END $$;
REVOKE ALL ON FUNCTION ritc.guardian_deletion_subject(text,text,uuid,uuid,uuid) FROM PUBLIC;

-- Bind the displayed account review to its membership, permission and device generations.
CREATE FUNCTION ritc.guardian_deletion_authority_digest(i text,target text) RETURNS text
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog AS $$
 WITH profiles AS (
   SELECT m.* FROM ritc.member m WHERE m.issuer=i AND m.subject=target
 )
 SELECT encode(sha256(convert_to(jsonb_build_array(
   ARRAY(SELECT jsonb_build_array(m.household_id,m.member_id,m.state) FROM profiles m ORDER BY m.household_id,m.member_id),
   ARRAY(SELECT DISTINCT jsonb_build_array(a.household_id,a.enrollment_id,e.state,e.consent_id)
      FROM ritc.guardian_deletion_admission a JOIN ritc.guardian_enrollment e USING(household_id,enrollment_id)
      WHERE a.issuer=i AND a.subject=target ORDER BY 1),
   ARRAY(SELECT jsonb_build_array(d.device_id,d.guardian_consent_id,d.revoked_at) FROM ritc.device d JOIN profiles USING(household_id,member_id) ORDER BY d.device_id)
 )::text,'utf8')),'hex')
$$;
REVOKE ALL ON FUNCTION ritc.guardian_deletion_authority_digest(text,text) FROM PUBLIC;

CREATE FUNCTION ritc.guardian_deletion_candidates(i text,s text,p uuid,h uuid,g uuid,d uuid,email_digest text)
RETURNS TABLE(enrollment_id uuid,child_alias text)
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT DISTINCT ON (a.subject) a.enrollment_id,a.child_alias FROM ritc.guardian_deletion_admission a
 WHERE a.household_id=h AND a.guardian_id=g AND a.guardian_issuer=i AND a.guardian_subject=s
   AND a.guardian_email_digest=email_digest AND ritc.guardian_confirmed_email(h,g,d,i,s,p::text) IS NOT NULL
   AND ritc.guardian_deletion_subject(i,s,p,h,a.enrollment_id)=a.subject
 ORDER BY a.subject,a.enrollment_id LIMIT 100
$$;

CREATE FUNCTION ritc.guardian_review_child_deletion(i text,s text,p uuid,h uuid,e uuid,g uuid,d uuid,guardian_digest text,child_digest text,child_email text)
RETURNS TABLE(review_id uuid,child_alias text,expires_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE target text; guardian_email text; actual_child_email text; alias_value text; review uuid:=gen_random_uuid(); expiry timestamptz:=clock_timestamp()+interval '5 minutes';
BEGIN
 guardian_email:=ritc.guardian_confirmed_email(h,g,d,i,s,p::text);
 target:=ritc.guardian_deletion_subject(i,s,p,h,e);
 IF guardian_email IS NULL OR target IS NULL THEN RETURN; END IF;
 SELECT u.email INTO actual_child_email FROM auth.users u WHERE u.id=target::uuid AND u.email_confirmed_at IS NOT NULL FOR SHARE;
 SELECT a.child_alias INTO alias_value FROM ritc.guardian_deletion_admission a WHERE a.household_id=h AND a.enrollment_id=e AND a.guardian_id=g
   AND a.subject=target AND a.guardian_email_digest=guardian_digest AND a.child_email_digest=child_digest;
 IF alias_value IS NULL OR actual_child_email IS NULL OR lower(trim(actual_child_email))<>lower(trim(child_email)) OR child_email IS NULL THEN RETURN; END IF;
 INSERT INTO ritc.guardian_child_deletion_review VALUES(h,e,review,d,p,target,ritc.guardian_deletion_authority_digest(i,target),
   encode(sha256(convert_to(review::text||guardian_email,'utf8')),'hex'),
   encode(sha256(convert_to(review::text||actual_child_email,'utf8')),'hex'),expiry)
 ON CONFLICT(household_id,enrollment_id) DO UPDATE SET review_id=excluded.review_id,device_id=d,session_id=p,target_subject=target,authority_digest=excluded.authority_digest,
   guardian_email_hash=excluded.guardian_email_hash,child_email_hash=excluded.child_email_hash,expires_at=expiry;
 RETURN QUERY SELECT review,alias_value,expiry;
END $$;

CREATE FUNCTION ritc.guardian_assert_deletion_review(i text,s text,p uuid,h uuid,e uuid,review uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE r ritc.guardian_child_deletion_review; target text; guardian_email text; child_email text;
BEGIN
 SELECT * INTO r FROM ritc.guardian_child_deletion_review WHERE household_id=h AND enrollment_id=e AND review_id=review AND session_id=p AND expires_at>clock_timestamp() FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'unavailable'; END IF;
 target:=ritc.guardian_deletion_subject(i,s,p,h,e);
 IF target IS DISTINCT FROM r.target_subject OR r.authority_digest IS DISTINCT FROM ritc.guardian_deletion_authority_digest(i,target) OR NOT EXISTS(SELECT 1 FROM ritc.device d JOIN ritc.member g USING(household_id,member_id)
     WHERE d.household_id=h AND d.device_id=r.device_id AND d.session_id=p::text AND d.revoked_at IS NULL AND g.issuer=i AND g.subject=s
      AND g.kind='adult' AND g.state='active' AND g.erased_at IS NULL) THEN RAISE EXCEPTION 'unavailable'; END IF;
 SELECT u.email INTO guardian_email FROM auth.users u WHERE id=s::uuid AND email_confirmed_at IS NOT NULL FOR SHARE;
 SELECT u.email INTO child_email FROM auth.users u WHERE id=target::uuid AND email_confirmed_at IS NOT NULL FOR SHARE;
 IF r.guardian_email_hash IS DISTINCT FROM encode(sha256(convert_to(review::text||guardian_email,'utf8')),'hex')
   OR r.child_email_hash IS DISTINCT FROM encode(sha256(convert_to(review::text||child_email,'utf8')),'hex') THEN RAISE EXCEPTION 'unavailable'; END IF;
 RETURN target;
END $$;
CREATE FUNCTION ritc.guardian_deletion_review_device(h uuid,e uuid,review uuid,d uuid,p uuid) RETURNS boolean
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT EXISTS(SELECT 1 FROM ritc.guardian_child_deletion_review WHERE household_id=h AND enrollment_id=e AND review_id=review AND device_id=d AND session_id=p AND expires_at>clock_timestamp())
$$;
REVOKE ALL ON FUNCTION ritc.guardian_deletion_candidates(text,text,uuid,uuid,uuid,uuid,text),ritc.guardian_review_child_deletion(text,text,uuid,uuid,uuid,uuid,uuid,text,text,text),ritc.guardian_assert_deletion_review(text,text,uuid,uuid,uuid,uuid),ritc.guardian_deletion_review_device(uuid,uuid,uuid,uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.guardian_deletion_candidates(text,text,uuid,uuid,uuid,uuid,text),ritc.guardian_review_child_deletion(text,text,uuid,uuid,uuid,uuid,uuid,text,text,text),ritc.guardian_assert_deletion_review(text,text,uuid,uuid,uuid,uuid),ritc.guardian_deletion_review_device(uuid,uuid,uuid,uuid,uuid) TO ritc_app;

-- Exceptional cases use private human review. Intake and reviewer permissions
-- confer no right to delete, join a household, contact another family, or access a receipt.
-- Request delivery is distinct from child authentication. A provider may have
-- created an account even if the client never receives or enters its OTP.
CREATE TABLE ritc.guardian_signup_request (
 household_id uuid NOT NULL,enrollment_id uuid NOT NULL,
 PRIMARY KEY(household_id,enrollment_id),
 FOREIGN KEY(household_id,enrollment_id) REFERENCES ritc.guardian_enrollment ON DELETE CASCADE
);
ALTER TABLE ritc.guardian_signup_request ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.guardian_signup_request FORCE ROW LEVEL SECURITY;
REVOKE ALL ON ritc.guardian_signup_request FROM PUBLIC,ritc_app,ritc_worker,ritc_guardian_verifier;
DO $$ BEGIN
 EXECUTE format('CREATE POLICY owner_scope ON ritc.guardian_signup_request TO %I USING(true) WITH CHECK(true)',current_user);
END $$;
INSERT INTO ritc.guardian_signup_request
 SELECT DISTINCT v.household_id,v.enrollment_id FROM ritc.guardian_child_invitation v WHERE
 EXISTS(SELECT 1 FROM ritc.guardian_native_challenge c WHERE c.household_id=v.household_id AND c.invite_id=v.invite_id)
 OR EXISTS(SELECT 1 FROM ritc.browser_auth b WHERE b.guardian_household_id=v.household_id AND b.guardian_invite_id=v.invite_id
   AND b.guardian_signin_started_at IS NOT NULL AND b.email_cipher IS NOT NULL);
CREATE FUNCTION ritc.guardian_note_signup_request(h uuid,inv uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE enrollment uuid;
BEGIN
 IF h::text IS DISTINCT FROM current_setting('app.household_id',true) THEN RETURN false; END IF;
 SELECT e.enrollment_id INTO enrollment FROM ritc.guardian_enrollment e JOIN ritc.guardian_child_invitation v USING(household_id,enrollment_id)
 WHERE v.household_id=h AND v.invite_id=inv AND e.state='consented' AND v.consumed_at IS NULL AND v.revoked_at IS NULL
   AND least(v.expires_at,e.expires_at)>clock_timestamp() AND (
    EXISTS(SELECT 1 FROM ritc.guardian_native_challenge c WHERE c.household_id=h AND c.invite_id=inv AND c.expires_at>clock_timestamp())
    OR EXISTS(SELECT 1 FROM ritc.browser_auth b WHERE b.guardian_household_id=h AND b.guardian_invite_id=inv AND b.phase='challenge'
       AND b.guardian_signin_started_at IS NOT NULL AND b.revoked_at IS NULL AND b.expires_at>clock_timestamp()));
 IF NOT FOUND THEN RETURN false; END IF;
 INSERT INTO ritc.guardian_signup_request VALUES(h,enrollment) ON CONFLICT DO NOTHING;
 RETURN true;
END $$;
REVOKE ALL ON FUNCTION ritc.guardian_note_signup_request(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.guardian_note_signup_request(uuid,uuid) TO ritc_app;

-- An unmatched case concerns only this enrollment and the guardian's own
-- attempted signup. No provider lookup or identity classification occurs.
CREATE VIEW ritc.guardian_unmatched_signup AS
 SELECT e.household_id,e.enrollment_id,e.guardian_id,e.guardian_issuer,e.guardian_subject,e.child_alias,e.child_email_digest,a.email_digest
 FROM ritc.guardian_signup_request q JOIN ritc.guardian_enrollment e USING(household_id,enrollment_id)
 JOIN ritc.guardian_attempt a USING(household_id,enrollment_id) JOIN ritc.guardian_provider_event pe USING(household_id,attempt_id)
 WHERE e.verified_at IS NOT NULL AND e.consented_at IS NOT NULL AND e.child_alias IS NOT NULL AND e.child_email_digest IS NOT NULL
 AND e.declaration='parent_or_legal_guardian' AND NOT EXISTS(SELECT 1 FROM ritc.guardian_deletion_admission x WHERE x.household_id=e.household_id AND x.enrollment_id=e.enrollment_id);
REVOKE ALL ON ritc.guardian_unmatched_signup FROM PUBLIC,ritc_app,ritc_worker,ritc_guardian_verifier;

CREATE TABLE ritc.guardian_deletion_case (
 request_id uuid PRIMARY KEY, household_id uuid NOT NULL, enrollment_id uuid NOT NULL,
 guardian_hash text NOT NULL, child_hash text,
 status text NOT NULL DEFAULT 'received' CHECK(status IN('received','in_review','verification_needed','closed')),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 expires_at timestamptz NOT NULL
);
CREATE UNIQUE INDEX guardian_deletion_case_open ON ritc.guardian_deletion_case(household_id,guardian_hash,child_hash) WHERE status<>'closed';
CREATE UNIQUE INDEX guardian_deletion_case_unmatched_open ON ritc.guardian_deletion_case(household_id,guardian_hash,enrollment_id) WHERE status<>'closed' AND child_hash IS NULL;
CREATE INDEX guardian_deletion_case_guardian ON ritc.guardian_deletion_case(guardian_hash);
CREATE INDEX guardian_deletion_case_child ON ritc.guardian_deletion_case(child_hash);
CREATE INDEX guardian_deletion_case_expiry ON ritc.guardian_deletion_case(expires_at);
ALTER TABLE ritc.guardian_deletion_case ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.guardian_deletion_case FORCE ROW LEVEL SECURITY;
REVOKE ALL ON ritc.guardian_deletion_case FROM PUBLIC,ritc_app,ritc_worker,ritc_guardian_verifier;
DO $$ BEGIN
 EXECUTE format('CREATE POLICY owner_scope ON ritc.guardian_deletion_case TO %I USING(true) WITH CHECK(true)',current_user);
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='ritc_guardian_case_reviewer') THEN
  CREATE ROLE ritc_guardian_case_reviewer NOLOGIN NOSUPERUSER NOBYPASSRLS;
 END IF;
END $$;
GRANT USAGE ON SCHEMA ritc TO ritc_guardian_case_reviewer;

CREATE FUNCTION ritc.guardian_case_receipt(r ritc.guardian_deletion_case) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $$
 SELECT jsonb_build_object('requestId',r.request_id,'status',r.status,'createdAt',r.created_at,'updatedAt',r.updated_at,'expiresAt',r.expires_at)
$$;
CREATE FUNCTION ritc.guardian_case_list(i text,s text,p uuid,h uuid,g uuid,d uuid,guardian_digest text,accepting boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE children jsonb:='[]'; receipts jsonb; actor_hash text:=encode(sha256(convert_to(i||E'\n'||s,'utf8')),'hex');
BEGIN
 IF ritc.guardian_confirmed_email(h,g,d,i,s,p::text) IS NULL THEN RAISE EXCEPTION 'unavailable'; END IF;
 IF accepting THEN
  SELECT coalesce(jsonb_agg(jsonb_build_object('enrollmentId',enrollment_id,'childAlias',child_alias,'identityState',identity_state)),'[]') INTO children FROM (
   SELECT DISTINCT a.enrollment_id,a.child_alias,'confirmed' AS identity_state FROM ritc.guardian_deletion_admission a
   WHERE a.household_id=h AND a.guardian_id=g AND a.guardian_issuer=i AND a.guardian_subject=s AND a.guardian_email_digest=guardian_digest
     AND a.issuer=i AND a.subject<>s AND NOT ritc.identity_blocked(i,a.subject)
     AND NOT ritc.identity_has_adult_profile(i,a.subject)
   UNION ALL SELECT u.enrollment_id,u.child_alias,'unmatched' FROM ritc.guardian_unmatched_signup u
   WHERE u.household_id=h AND u.guardian_id=g AND u.guardian_issuer=i AND u.guardian_subject=s AND u.email_digest=guardian_digest
   ORDER BY child_alias,enrollment_id LIMIT 100
  ) candidates;
 END IF;
 SELECT coalesce(jsonb_agg(ritc.guardian_case_receipt(r.item) ORDER BY r.created_at DESC),'[]') INTO receipts FROM (
  SELECT c AS item,c.created_at FROM ritc.guardian_deletion_case c WHERE household_id=h AND guardian_hash=actor_hash AND expires_at>clock_timestamp() ORDER BY created_at DESC LIMIT 100
 ) r;
 RETURN jsonb_build_object('available',accepting,'children',children,'requests',receipts);
END $$;

CREATE FUNCTION ritc.guardian_case_open(i text,s text,p uuid,h uuid,g uuid,d uuid,e uuid,k uuid,guardian_digest text,child_digest text,child_email text,days integer,unmatched_days integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor_hash text:=encode(sha256(convert_to(i||E'\n'||s,'utf8')),'hex'); target text; target_hash text; prior ritc.guardian_deletion_case;
BEGIN
 IF days IS NULL OR days NOT BETWEEN 1 AND 365 OR unmatched_days IS NULL OR unmatched_days NOT BETWEEN 1 AND 365 OR ritc.guardian_confirmed_email(h,g,d,i,s,p::text) IS NULL THEN RAISE EXCEPTION 'unavailable'; END IF;
 -- Exact current provider-confirmed address AND the child's authenticated admission.
 -- The address only exists in this bound query and is never a durable case field.
 SELECT a.subject INTO target FROM ritc.guardian_deletion_admission a JOIN auth.users u ON u.id=a.subject::uuid
 WHERE a.household_id=h AND a.enrollment_id=e AND a.guardian_id=g AND a.guardian_issuer=i AND a.guardian_subject=s AND a.issuer=i
  AND a.guardian_email_digest=guardian_digest AND a.child_email_digest=child_digest AND a.subject<>s
  AND u.email_confirmed_at IS NOT NULL AND lower(trim(u.email))=lower(trim(child_email))
  AND NOT ritc.identity_has_adult_profile(i,a.subject) FOR SHARE OF u;
 IF NOT ritc.guardian_lock_identity(i,s) THEN RAISE EXCEPTION 'unavailable'; END IF;
 IF target IS NULL THEN
  IF NOT EXISTS(SELECT 1 FROM ritc.guardian_unmatched_signup u WHERE u.household_id=h AND u.enrollment_id=e AND u.guardian_id=g AND u.guardian_issuer=i AND u.guardian_subject=s
     AND u.email_digest=guardian_digest AND u.child_email_digest=child_digest) THEN RAISE EXCEPTION 'unavailable'; END IF;
  days:=unmatched_days;
 ELSIF NOT ritc.guardian_lock_identity(i,target) THEN RAISE EXCEPTION 'unavailable'; END IF;
 target_hash:=encode(sha256(convert_to(i||E'\n'||target,'utf8')),'hex');
 SELECT * INTO prior FROM ritc.guardian_deletion_case WHERE request_id=k;
 IF FOUND THEN
  IF prior.household_id<>h OR prior.enrollment_id<>e OR prior.guardian_hash<>actor_hash OR (prior.child_hash IS NOT NULL AND prior.child_hash IS DISTINCT FROM target_hash) OR prior.expires_at<=clock_timestamp()
  THEN RAISE EXCEPTION 'key_reused'; END IF;
  RETURN ritc.guardian_case_receipt(prior);
 END IF;
 DELETE FROM ritc.guardian_deletion_case WHERE household_id=h AND guardian_hash=actor_hash AND (child_hash=target_hash OR (enrollment_id=e AND child_hash IS NULL)) AND expires_at<=clock_timestamp();
 IF EXISTS(SELECT 1 FROM ritc.guardian_deletion_case WHERE household_id=h AND guardian_hash=actor_hash AND enrollment_id=e AND status<>'closed' AND expires_at>clock_timestamp()) THEN RAISE EXCEPTION 'review_already_requested'; END IF;
 INSERT INTO ritc.guardian_deletion_case(request_id,household_id,enrollment_id,guardian_hash,child_hash,expires_at)
 VALUES(k,h,e,actor_hash,target_hash,clock_timestamp()+make_interval(days=>days)) RETURNING * INTO prior;
 RETURN ritc.guardian_case_receipt(prior);
EXCEPTION WHEN unique_violation THEN RAISE EXCEPTION 'review_already_requested';
END $$;
CREATE FUNCTION ritc.guardian_case_queue(batch_size integer) RETURNS TABLE(request_id uuid,household_id uuid,enrollment_id uuid,identity_state text,status text,created_at timestamptz,expires_at timestamptz)
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT c.request_id,c.household_id,c.enrollment_id,CASE WHEN c.child_hash IS NULL THEN 'unmatched' ELSE 'confirmed' END,c.status,c.created_at,c.expires_at FROM ritc.guardian_deletion_case c
 WHERE c.expires_at>clock_timestamp() AND c.status<>'closed' ORDER BY c.created_at,c.request_id LIMIT least(greatest(batch_size,1),100)
$$;
CREATE FUNCTION ritc.guardian_case_update(k uuid,expected text,next_status text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF next_status NOT IN('in_review','verification_needed','closed') THEN RETURN false; END IF;
 UPDATE ritc.guardian_deletion_case SET status=next_status,updated_at=clock_timestamp() WHERE request_id=k AND status=expected AND status<>'closed' AND expires_at>clock_timestamp();
 RETURN FOUND;
END $$;
REVOKE ALL ON FUNCTION ritc.guardian_case_receipt(ritc.guardian_deletion_case),ritc.guardian_case_list(text,text,uuid,uuid,uuid,uuid,text,boolean),ritc.guardian_case_open(text,text,uuid,uuid,uuid,uuid,uuid,uuid,text,text,text,integer,integer),ritc.guardian_case_queue(integer),ritc.guardian_case_update(uuid,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.guardian_case_list(text,text,uuid,uuid,uuid,uuid,text,boolean),ritc.guardian_case_open(text,text,uuid,uuid,uuid,uuid,uuid,uuid,text,text,text,integer,integer) TO ritc_app;
GRANT EXECUTE ON FUNCTION ritc.guardian_case_queue(integer),ritc.guardian_case_update(uuid,text,text) TO ritc_guardian_case_reviewer;

-- Once an unmatched case's enrollment is erased/retired, remove its remaining
-- investigation references. A future child identity is never attributed by address.
CREATE FUNCTION ritc.guardian_case_retire_unmatched() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 DELETE FROM ritc.guardian_deletion_case WHERE household_id=OLD.household_id AND enrollment_id=OLD.enrollment_id AND child_hash IS NULL;
 RETURN OLD;
END $$;
REVOKE ALL ON FUNCTION ritc.guardian_case_retire_unmatched() FROM PUBLIC;
CREATE TRIGGER guardian_case_retire_unmatched BEFORE DELETE ON ritc.guardian_enrollment FOR EACH ROW EXECUTE FUNCTION ritc.guardian_case_retire_unmatched();
CREATE FUNCTION ritc.guardian_case_erase() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 DELETE FROM ritc.guardian_deletion_case WHERE guardian_hash=NEW.identity_hash OR child_hash=NEW.identity_hash;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ritc.guardian_case_erase() FROM PUBLIC;
CREATE TRIGGER guardian_case_erase AFTER INSERT ON ritc.identity_erasure FOR EACH ROW EXECUTE FUNCTION ritc.guardian_case_erase();
ALTER FUNCTION ritc.guardian_housekeeping(integer,integer,integer) RENAME TO guardian_housekeeping_v021;
REVOKE ALL ON FUNCTION ritc.guardian_housekeeping_v021(integer,integer,integer) FROM ritc_worker;
CREATE FUNCTION ritc.guardian_housekeeping(batch_size integer,pending_hours integer DEFAULT NULL,evidence_days integer DEFAULT NULL) RETURNS TABLE(expired integer,purged integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 DELETE FROM ritc.guardian_child_deletion_review WHERE review_id IN(SELECT review_id FROM ritc.guardian_child_deletion_review WHERE expires_at<=clock_timestamp() ORDER BY expires_at LIMIT least(greatest(batch_size,1),100) FOR UPDATE SKIP LOCKED);
 DELETE FROM ritc.guardian_deletion_case WHERE request_id IN(SELECT request_id FROM ritc.guardian_deletion_case WHERE expires_at<=clock_timestamp() ORDER BY expires_at LIMIT least(greatest(batch_size,1),100) FOR UPDATE SKIP LOCKED);
 RETURN QUERY SELECT * FROM ritc.guardian_housekeeping_v021(batch_size,pending_hours,evidence_days);
END $$;
REVOKE ALL ON FUNCTION ritc.guardian_housekeeping(integer,integer,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.guardian_housekeeping(integer,integer,integer) TO ritc_worker;
