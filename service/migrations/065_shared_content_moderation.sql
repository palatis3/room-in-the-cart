-- Attribution is recorded by the authorized publisher on new writes. A NULL
-- historical author must never be replaced with the current shopper.
ALTER TABLE ritc.request ADD COLUMN wording_revision integer NOT NULL DEFAULT 1 CHECK(wording_revision>0),
 ADD COLUMN clarification_revision integer CHECK(clarification_revision>0),
 ADD COLUMN clarification_author_id uuid,
 ADD FOREIGN KEY (household_id,clarification_author_id) REFERENCES ritc.member;
ALTER TABLE ritc.view_grant ADD COLUMN projection_author_id uuid,
 ADD COLUMN projection_wording_revision integer NOT NULL DEFAULT 1 CHECK(projection_wording_revision>0),
 ADD FOREIGN KEY (household_id,projection_author_id) REFERENCES ritc.member;

-- Every published replacement advances the grant revision. For a still-live,
-- never-replaced initial grant, created_by is the recorded publisher.
UPDATE ritc.view_grant SET projection_author_id=created_by WHERE revision=1 AND revoked_at IS NULL;

CREATE TABLE ritc.moderation_block (
 household_id uuid NOT NULL, viewer_id uuid NOT NULL, author_id uuid NOT NULL,
 PRIMARY KEY(household_id,viewer_id,author_id), CHECK(viewer_id<>author_id),
 FOREIGN KEY(household_id,viewer_id) REFERENCES ritc.member,
 FOREIGN KEY(household_id,author_id) REFERENCES ritc.member
);
CREATE TABLE ritc.moderation_removal (
 household_id uuid NOT NULL REFERENCES ritc.household, source_kind text NOT NULL,
 source_id uuid NOT NULL, source_revision integer NOT NULL CHECK(source_revision>0),
 PRIMARY KEY(household_id,source_kind,source_id,source_revision)
);
-- Only a privileged adjudication can suspend an identity across memberships.
CREATE TABLE ritc.moderation_suspension (
 identity_hash text PRIMARY KEY CHECK(length(identity_hash)=64), suspended_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE ritc.moderation_receipt (
 household_id uuid NOT NULL, reporter_id uuid NOT NULL, client_key uuid NOT NULL, fingerprint text NOT NULL,
 receipt_id uuid NOT NULL UNIQUE, status text NOT NULL CHECK(status IN ('received','blocked')),
 expires_at timestamptz NOT NULL,
 PRIMARY KEY(household_id,reporter_id,client_key),
 FOREIGN KEY(household_id,reporter_id) REFERENCES ritc.member
);
CREATE TABLE ritc.moderation_case (
 case_id uuid PRIMARY KEY, household_id uuid NOT NULL, reporter_id uuid NOT NULL, author_id uuid,
 source_kind text NOT NULL CHECK(source_kind IN ('request','clarification','instruction','suggestion','cookCopy')),
 source_id uuid NOT NULL, source_revision integer NOT NULL CHECK(source_revision>0), source_field text NOT NULL,
 field_index integer CHECK(field_index BETWEEN 0 AND 199),
 reason text NOT NULL CHECK(reason IN ('harassment','unsafe','other')),
 excerpt text CHECK(length(excerpt) BETWEEN 1 AND 1000),
 created_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz NOT NULL CHECK(expires_at>created_at),
 resolution text CHECK(resolution IN ('dismiss','remove','suspend')), resolved_at timestamptz, resolved_by name,
 CHECK((resolution IS NULL)=(resolved_at IS NULL) AND (resolution IS NULL)=(resolved_by IS NULL)),
 FOREIGN KEY(household_id,reporter_id) REFERENCES ritc.member,
 FOREIGN KEY(household_id,author_id) REFERENCES ritc.member
);
CREATE INDEX moderation_case_queue ON ritc.moderation_case(created_at,case_id) WHERE resolution IS NULL;
CREATE INDEX moderation_case_expiry ON ritc.moderation_case(expires_at);
CREATE INDEX moderation_receipt_expiry ON ritc.moderation_receipt(expires_at);
DO $$ DECLARE relation text; BEGIN
 FOREACH relation IN ARRAY ARRAY['moderation_block','moderation_removal','moderation_receipt','moderation_case'] LOOP
  EXECUTE format('ALTER TABLE ritc.%I ENABLE ROW LEVEL SECURITY',relation);
  EXECUTE format('ALTER TABLE ritc.%I FORCE ROW LEVEL SECURITY',relation);
  EXECUTE format('CREATE POLICY tenant_scope ON ritc.%I TO ritc_app USING(household_id::text=(SELECT current_setting(''app.household_id'',true))) WITH CHECK(household_id::text=(SELECT current_setting(''app.household_id'',true)))',relation);
 END LOOP;
 IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='ritc_moderator') THEN
  CREATE ROLE ritc_moderator NOLOGIN NOSUPERUSER NOBYPASSRLS;
 END IF;
END $$;
ALTER TABLE ritc.moderation_suspension ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.moderation_suspension FORCE ROW LEVEL SECURITY;
GRANT INSERT ON ritc.moderation_block,ritc.moderation_case TO ritc_app;
GRANT SELECT,INSERT ON ritc.moderation_receipt TO ritc_app;

CREATE FUNCTION ritc.content_account_suspended(h uuid, person uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT EXISTS(SELECT FROM ritc.member m JOIN ritc.moderation_suspension s
 ON s.identity_hash=encode(sha256(convert_to(m.issuer||E'\n'||m.subject,'utf8')),'hex')
 WHERE h::text=current_setting('app.household_id',true) AND m.household_id=h AND m.member_id=person)
$$;
CREATE FUNCTION ritc.shared_content_visible(h uuid, viewer uuid, author uuid, kind text, source uuid, first_revision integer, current_revision integer) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT coalesce(h::text=current_setting('app.household_id',true),false) AND viewer IS NOT NULL
  AND NOT ritc.content_account_suspended(h,author)
  AND NOT EXISTS(SELECT FROM ritc.moderation_block WHERE household_id=h AND viewer_id=viewer AND author_id=author)
  AND NOT EXISTS(SELECT FROM ritc.moderation_removal WHERE household_id=h AND source_kind=kind AND source_id=source
                 AND source_revision BETWEEN coalesce(first_revision,1) AND current_revision)
$$;
REVOKE ALL ON FUNCTION ritc.content_account_suspended(uuid,uuid),ritc.shared_content_visible(uuid,uuid,uuid,text,uuid,integer,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.content_account_suspended(uuid,uuid),ritc.shared_content_visible(uuid,uuid,uuid,text,uuid,integer,integer) TO ritc_app;

-- The operator can see only the evidence the reporting person explicitly chose.
-- The runtime, guardian, planner and support mailbox have no queue capability.
CREATE FUNCTION ritc.moderation_queue() RETURNS TABLE(case_id uuid,submitted timestamptz,expires timestamptz,
 kind text,field text,reason text,excerpt text,sender_known boolean)
LANGUAGE sql SECURITY DEFINER STABLE SET search_path=pg_catalog AS $$
 SELECT c.case_id,c.created_at,c.expires_at,c.source_kind,c.source_field,c.reason,c.excerpt,c.author_id IS NOT NULL
 FROM ritc.moderation_case c WHERE c.resolution IS NULL AND c.expires_at>now()
 ORDER BY c.created_at,c.case_id LIMIT 50
$$;
CREATE FUNCTION ritc.moderation_resolve(target uuid, decision text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE report ritc.moderation_case%ROWTYPE;
BEGIN
 IF decision IS NULL OR decision NOT IN ('dismiss','remove','suspend') THEN RAISE EXCEPTION 'invalid resolution'; END IF;
 SELECT * INTO STRICT report FROM ritc.moderation_case WHERE case_id=target AND expires_at>now() FOR UPDATE;
 IF report.resolution IS NOT NULL THEN
  IF report.resolution<>decision THEN RAISE EXCEPTION 'already resolved'; END IF;
  RETURN report.resolution;
 END IF;
 IF decision='suspend' THEN
  IF report.author_id IS NULL THEN RAISE EXCEPTION 'sender unavailable'; END IF;
  INSERT INTO ritc.moderation_suspension(identity_hash)
   SELECT encode(sha256(convert_to(m.issuer||E'\n'||m.subject,'utf8')),'hex') FROM ritc.member m
    WHERE m.household_id=report.household_id AND m.member_id=report.author_id ON CONFLICT DO NOTHING;
 END IF;
 IF decision IN ('remove','suspend') THEN
  INSERT INTO ritc.moderation_removal VALUES(report.household_id,report.source_kind,report.source_id,report.source_revision)
   ON CONFLICT DO NOTHING;
 END IF;
 UPDATE ritc.moderation_case SET resolution=decision,resolved_at=now(),resolved_by=session_user WHERE case_id=target;
 RETURN decision;
END $$;
CREATE FUNCTION ritc.moderation_workload() RETURNS TABLE(pending bigint,oldest_pending_at timestamptz,
 earliest_evidence_expiry timestamptz,expired_unreviewed bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT count(*) FILTER(WHERE expires_at>now()),min(created_at) FILTER(WHERE expires_at>now()),
 min(expires_at) FILTER(WHERE expires_at>now()),count(*) FILTER(WHERE expires_at<=now())
 FROM ritc.moderation_case WHERE resolution IS NULL
$$;
CREATE FUNCTION ritc.moderation_prune() RETURNS TABLE(expired_cases bigint,expired_receipts bigint,expired_unreviewed bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 WITH expired AS (DELETE FROM ritc.moderation_case WHERE expires_at<=now() RETURNING resolution)
 SELECT count(*),count(*) FILTER(WHERE resolution IS NULL) INTO expired_cases,expired_unreviewed FROM expired;
 DELETE FROM ritc.moderation_receipt WHERE expires_at<=now();
 GET DIAGNOSTICS expired_receipts=ROW_COUNT;
 RETURN NEXT;
END $$;
REVOKE ALL ON FUNCTION ritc.moderation_queue(),ritc.moderation_resolve(uuid,text),ritc.moderation_workload(),ritc.moderation_prune() FROM PUBLIC;
GRANT USAGE ON SCHEMA ritc TO ritc_moderator;
GRANT EXECUTE ON FUNCTION ritc.moderation_queue(),ritc.moderation_resolve(uuid,text),ritc.moderation_workload(),ritc.moderation_prune() TO ritc_moderator;

ALTER FUNCTION ritc.privacy_erase_extension(uuid,uuid) RENAME TO privacy_erase_before_moderation;
CREATE FUNCTION ritc.privacy_erase_extension(target_household uuid,target_member uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 DELETE FROM ritc.moderation_receipt WHERE household_id=target_household AND reporter_id=target_member;
 DELETE FROM ritc.moderation_case WHERE household_id=target_household AND (reporter_id=target_member OR author_id=target_member);
 DELETE FROM ritc.moderation_block WHERE household_id=target_household AND (viewer_id=target_member OR author_id=target_member);
 DELETE FROM ritc.moderation_suspension s USING ritc.member m
 WHERE (m.household_id,m.member_id)=(target_household,target_member)
 AND s.identity_hash=encode(sha256(convert_to(m.issuer||E'\n'||m.subject,'utf8')),'hex');
 UPDATE ritc.request SET clarification=NULL,clarification_revision=NULL,clarification_author_id=NULL
 WHERE household_id=target_household AND clarification_author_id=target_member;
 UPDATE ritc.view_grant SET projection_author_id=NULL,projection='{"items":[],"shopLabel":"Removed view","language":"en"}'::jsonb,revoked_at=coalesce(revoked_at,now())
 WHERE household_id=target_household AND projection_author_id=target_member;
 PERFORM ritc.privacy_erase_before_moderation(target_household,target_member);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_extension(uuid,uuid) FROM PUBLIC;
