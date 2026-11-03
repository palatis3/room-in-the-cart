-- A managed lost-device revocation must not be bypassed by minting a new
-- enrollment with the same provider session. Sibling enrollments stay active.
-- The owner-only table stores a hash, never the raw provider session.
CREATE TABLE ritc.device_enrollment_fence (
 household_id uuid NOT NULL,
 member_id uuid NOT NULL,
 session_hash text NOT NULL CHECK(session_hash ~ '^[0-9a-f]{64}$'),
 revoked_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(household_id,member_id,session_hash),
 FOREIGN KEY(household_id,member_id) REFERENCES ritc.member
);
ALTER TABLE ritc.device_enrollment_fence ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.device_enrollment_fence FORCE ROW LEVEL SECURITY;
DO $$ BEGIN
 EXECUTE format('CREATE POLICY owner_scope ON ritc.device_enrollment_fence TO %I USING(true) WITH CHECK(true)',current_user);
END $$;
REVOKE ALL ON ritc.device_enrollment_fence FROM PUBLIC,ritc_app;
-- Application paths only retire a credential. Replacing/erasing credential
-- columns belongs to the narrow owner functions, including the erasure hook.
REVOKE UPDATE ON ritc.device FROM ritc_app;
GRANT UPDATE(revoked_at) ON ritc.device TO ritc_app;

-- No caller-supplied hash can create a denial. Check the exact live adult
-- principal/session before answering whether this account may enroll again.
CREATE FUNCTION ritc.device_enrollment_permitted(h uuid,m uuid,i text,s text,p text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF h::text IS DISTINCT FROM current_setting('app.household_id',true) OR NOT EXISTS(
  SELECT 1 FROM ritc.member WHERE household_id=h AND member_id=m AND issuer=i AND subject=s
  AND kind='adult' AND state='active' AND erased_at IS NULL
 ) THEN RETURN false; END IF;
 IF NOT ritc.provider_session_live(p::uuid,s::uuid) OR ritc.identity_blocked(i,s) THEN RETURN false; END IF;
 RETURN NOT EXISTS(SELECT 1 FROM ritc.device_enrollment_fence WHERE household_id=h AND member_id=m
  AND session_hash=encode(sha256(convert_to(p,'utf8')),'hex'));
EXCEPTION WHEN invalid_text_representation THEN RETURN false;
END $$;
REVOKE ALL ON FUNCTION ritc.device_enrollment_permitted(uuid,uuid,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.device_enrollment_permitted(uuid,uuid,text,text,text) TO ritc_app;

-- Derive the fence only from the authorized target device. This entry point
-- rechecks live member/device/session and organizer or actual guardian scope.
CREATE FUNCTION ritc.revoke_household_device(h uuid,a uuid,d uuid,i text,s text,p text,t uuid,m uuid) RETURNS timestamptz
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor ritc.member%ROWTYPE; target record; revoked timestamptz;
BEGIN
 IF h::text IS DISTINCT FROM current_setting('app.household_id',true) OR d=t THEN RETURN NULL; END IF;
 PERFORM 1 FROM ritc.household WHERE household_id=h FOR UPDATE;
 SELECT u.* INTO actor FROM ritc.member u JOIN ritc.device v USING(household_id,member_id)
  WHERE u.household_id=h AND u.member_id=a AND u.issuer=i AND u.subject=s AND u.kind='adult'
  AND u.state='active' AND u.erased_at IS NULL AND v.device_id=d AND v.session_id=p AND v.revoked_at IS NULL;
 IF NOT FOUND OR NOT ritc.provider_session_live(p::uuid,s::uuid) OR ritc.identity_blocked(i,s) THEN RETURN NULL; END IF;
 SELECT v.session_id,v.revoked_at,u.kind INTO target FROM ritc.device v JOIN ritc.member u USING(household_id,member_id)
  WHERE v.household_id=h AND v.device_id=t AND v.member_id=m;
 IF NOT FOUND OR NOT (actor.organizer OR (target.kind='child' AND EXISTS(
  SELECT 1 FROM ritc.guardian_relationship WHERE household_id=h AND child_id=m AND guardian_id=a AND revoked_at IS NULL
 ))) THEN RETURN NULL; END IF;
 revoked=COALESCE(target.revoked_at,clock_timestamp());
 IF target.session_id<>'erased' THEN
  INSERT INTO ritc.device_enrollment_fence(household_id,member_id,session_hash,revoked_at)
   VALUES(h,m,encode(sha256(convert_to(target.session_id,'utf8')),'hex'),revoked) ON CONFLICT DO NOTHING;
 END IF;
 UPDATE ritc.web_session SET revoked_at=COALESCE(revoked_at,revoked) WHERE household_id=h AND member_id=m AND device_id=t;
 UPDATE ritc.replay_window SET revoked_at=COALESCE(revoked_at,revoked) WHERE household_id=h AND member_id=m AND device_id=t;
 UPDATE ritc.device SET revoked_at=COALESCE(revoked_at,revoked) WHERE household_id=h AND member_id=m AND device_id=t;
 RETURN revoked;
EXCEPTION WHEN invalid_text_representation THEN RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION ritc.revoke_household_device(uuid,uuid,uuid,text,text,text,uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.revoke_household_device(uuid,uuid,uuid,text,text,text,uuid,uuid) TO ritc_app;

-- Defense at the existing runtime INSERT boundary as well as HTTP enrollment.
CREATE FUNCTION ritc.device_enrollment_fenced() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 PERFORM 1 FROM ritc.household WHERE household_id=NEW.household_id FOR UPDATE;
 IF EXISTS(SELECT 1 FROM ritc.device_enrollment_fence f WHERE f.household_id=NEW.household_id
  AND f.member_id=NEW.member_id AND f.session_hash=encode(sha256(convert_to(NEW.session_id,'utf8')),'hex')) THEN
  RAISE EXCEPTION 'device enrollment requires fresh session' USING ERRCODE='23514';
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ritc.device_enrollment_fenced() FROM PUBLIC;
CREATE TRIGGER device_enrollment_fenced BEFORE INSERT ON ritc.device
 FOR EACH ROW EXECUTE FUNCTION ritc.device_enrollment_fenced();

-- privacy_erase_member already erases device.session_id under the table owner.
-- This hook also runs when the deletion journal reapplies erasure after restore.
CREATE FUNCTION ritc.erase_device_enrollment_fences() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 DELETE FROM ritc.device_enrollment_fence WHERE household_id=NEW.household_id AND member_id=NEW.member_id;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ritc.erase_device_enrollment_fences() FROM PUBLIC;
CREATE TRIGGER erase_device_enrollment_fences AFTER UPDATE OF session_id ON ritc.device
 FOR EACH ROW WHEN (NEW.session_id='erased') EXECUTE FUNCTION ritc.erase_device_enrollment_fences();
