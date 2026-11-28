-- Explicit, address-bound transactional contact. The address remains with the identity provider.
CREATE TABLE ritc.renewal_contact (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), household_id uuid NOT NULL, purchaser_id uuid NOT NULL,
 sandbox_only boolean NOT NULL DEFAULT false, address_digest bytea NOT NULL CHECK(octet_length(address_digest)=32),
 original_id text CHECK(original_id ~ '^[0-9]{1,64}$'), enrolled_at timestamptz NOT NULL DEFAULT now(),
 next_check timestamptz NOT NULL DEFAULT now(), attention boolean NOT NULL DEFAULT false,
 UNIQUE(household_id,purchaser_id),
 FOREIGN KEY(household_id,purchaser_id) REFERENCES ritc.member ON DELETE CASCADE
);
CREATE INDEX renewal_contact_due ON ritc.renewal_contact(next_check,id) WHERE original_id IS NOT NULL;
CREATE TABLE ritc.renewal_dispatch (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), household_id uuid NOT NULL,purchaser_id uuid NOT NULL,
 contact_id uuid NOT NULL, original_id text NOT NULL, term text NOT NULL CHECK(term ~ '^[0-9]{1,64}$'),
 edition integer NOT NULL CHECK(edition>=1), purpose text NOT NULL CHECK(purpose IN ('reminder','correction')), due_at timestamptz NOT NULL, amount_milli bigint NOT NULL CHECK(amount_milli>0),
 signed_at timestamptz NOT NULL, first_attempt timestamptz NOT NULL DEFAULT now(), purge_at timestamptz NOT NULL,
 state text NOT NULL DEFAULT 'attempted' CHECK(state IN ('attempted','accepted','delivered','failed')),
 provider_id uuid,
 UNIQUE(household_id,purchaser_id,original_id,term,edition),
 FOREIGN KEY(household_id,purchaser_id) REFERENCES ritc.member ON DELETE CASCADE
);
CREATE INDEX renewal_dispatch_purge ON ritc.renewal_dispatch(purge_at);
ALTER TABLE ritc.renewal_contact ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.renewal_contact FORCE ROW LEVEL SECURITY;
ALTER TABLE ritc.renewal_dispatch ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.renewal_dispatch FORCE ROW LEVEL SECURITY;
CREATE POLICY renewal_contact_app ON ritc.renewal_contact TO ritc_app
 USING(household_id::text=current_setting('app.household_id',true))
 WITH CHECK(household_id::text=current_setting('app.household_id',true));
CREATE POLICY renewal_contact_worker ON ritc.renewal_contact TO ritc_worker USING(true) WITH CHECK(true);
CREATE POLICY renewal_dispatch_worker ON ritc.renewal_dispatch TO ritc_worker USING(true) WITH CHECK(true);
GRANT SELECT,INSERT,DELETE ON ritc.renewal_contact TO ritc_app;
GRANT UPDATE(original_id,next_check,attention) ON ritc.renewal_contact TO ritc_app;
GRANT SELECT,DELETE ON ritc.renewal_contact TO ritc_worker;
GRANT UPDATE(next_check,attention) ON ritc.renewal_contact TO ritc_worker;
GRANT SELECT,INSERT,DELETE ON ritc.renewal_dispatch TO ritc_worker;
GRANT UPDATE(state,provider_id) ON ritc.renewal_dispatch TO ritc_worker;

-- A backup can predate an accepted provider request. This fence contains no payer identifiers.
CREATE TABLE ritc.renewal_restore_fence (
 singleton boolean PRIMARY KEY CHECK(singleton), restored_at timestamptz NOT NULL
);
ALTER TABLE ritc.renewal_restore_fence ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.renewal_restore_fence FORCE ROW LEVEL SECURITY;
REVOKE ALL ON ritc.renewal_restore_fence FROM PUBLIC,ritc_app,ritc_worker;

-- Only the bound purchaser's current confirmed address is resolved, under the same identity
-- lock used by account erasure. No caller-supplied destination or arbitrary account lookup.
CREATE FUNCTION ritc.renewal_worker_contact(enrollment uuid, expected_issuer text)
RETURNS TABLE(destination text, subscription jsonb) LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog SET row_security=off AS $$
DECLARE identity_key text;
BEGIN
 SELECT encode(sha256(convert_to(m.issuer||E'\n'||m.subject,'UTF8')),'hex') INTO identity_key
 FROM ritc.renewal_contact c JOIN ritc.member m ON (m.household_id,m.member_id)=(c.household_id,c.purchaser_id)
 WHERE c.id=enrollment AND NOT c.sandbox_only AND m.issuer=expected_issuer AND m.kind='adult' AND m.state='active' AND m.erased_at IS NULL;
 IF NOT pg_try_advisory_xact_lock_shared(hashtextextended('ritc.renewal_restore_fence',0)) THEN RETURN; END IF;
 IF identity_key IS NULL OR NOT pg_try_advisory_xact_lock_shared(hashtextextended(identity_key,0)) THEN RETURN; END IF;
 RETURN QUERY SELECT trim(u.email)::text,s.subscription
 FROM ritc.renewal_contact c JOIN ritc.member m ON (m.household_id,m.member_id)=(c.household_id,c.purchaser_id)
 JOIN auth.users u ON u.id::text=m.subject
 JOIN ritc.billing_state s ON (s.household_id,s.purchaser_id)=(c.household_id,c.purchaser_id)
 JOIN ritc.billing_binding b ON (b.household_id,b.purchaser_id)=(c.household_id,c.purchaser_id)
 WHERE c.id=enrollment AND NOT c.sandbox_only AND m.issuer=expected_issuer AND m.kind='adult' AND m.state='active' AND m.erased_at IS NULL
 AND NOT ritc.identity_blocked(m.issuer,m.subject) AND u.email_confirmed_at IS NOT NULL
 AND c.address_digest=sha256(convert_to(c.id::text||E'\n'||lower(trim(u.email)),'UTF8'))
 AND b.environment='Production' AND b.original_transaction_id=c.original_id
 AND b.app_account_token::text=s.subscription->>'appAccountToken'
 AND s.subscription->>'environment'='Production' AND s.subscription->>'originalTransactionID'=c.original_id
 AND s.subscription->>'mxAnnual'='true'
 AND NOT EXISTS(SELECT 1 FROM ritc.renewal_restore_fence f
  WHERE to_timestamp((s.subscription->>'purchasedAt')::double precision/1000)<=f.restored_at)
 FOR SHARE OF m,u,s;
END $$;
REVOKE ALL ON FUNCTION ritc.renewal_worker_contact(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.renewal_worker_contact(uuid,text) TO ritc_worker;

-- A paid series can only activate a timely enrollment by its actual, verified purchaser.
CREATE FUNCTION ritc.bind_renewal_contact() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog SET row_security=off AS $$
BEGIN
 IF NEW.subscription->>'environment'='Production' AND NEW.subscription->>'mxAnnual'='true' AND NEW.subscription->>'status'='active' THEN
  UPDATE ritc.renewal_contact SET original_id=NEW.subscription->>'originalTransactionID',next_check=now()
  WHERE household_id=NEW.household_id AND purchaser_id=NEW.purchaser_id AND NOT sandbox_only
    AND ((original_id IS NULL AND enrolled_at>now()-interval '30 days') OR original_id=NEW.subscription->>'originalTransactionID');
 ELSE
  DELETE FROM ritc.renewal_contact WHERE household_id=NEW.household_id AND purchaser_id=NEW.purchaser_id
   AND NOT sandbox_only AND original_id IS NOT NULL;
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ritc.bind_renewal_contact() FROM PUBLIC;
CREATE TRIGGER bind_renewal_contact AFTER INSERT OR UPDATE OF subscription ON ritc.billing_state
 FOR EACH ROW EXECUTE FUNCTION ritc.bind_renewal_contact();

-- Aggregate only. Account deletion cannot leave an address or a reconnectable recipient.
CREATE TABLE ritc.renewal_route_loss(day date PRIMARY KEY, count integer NOT NULL CHECK(count>0));
ALTER TABLE ritc.renewal_route_loss ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.renewal_route_loss FORCE ROW LEVEL SECURITY;
REVOKE ALL ON ritc.renewal_route_loss FROM PUBLIC,ritc_app,ritc_worker;
CREATE FUNCTION ritc.note_renewal_route_loss(n bigint) RETURNS void LANGUAGE sql SECURITY DEFINER
SET search_path=pg_catalog SET row_security=off AS $$
 INSERT INTO ritc.renewal_route_loss(day,count) SELECT (now() AT TIME ZONE 'UTC')::date,n::integer WHERE n>0
 ON CONFLICT(day) DO UPDATE SET count=ritc.renewal_route_loss.count+excluded.count
$$;
REVOKE ALL ON FUNCTION ritc.note_renewal_route_loss(bigint) FROM PUBLIC;

CREATE FUNCTION ritc.forget_renewal_member() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog SET row_security=off AS $$
BEGIN
 PERFORM ritc.note_renewal_route_loss(count(*)) FROM ritc.renewal_contact WHERE original_id IS NOT NULL
  AND (household_id,purchaser_id)=(OLD.household_id,OLD.member_id);
 DELETE FROM ritc.renewal_dispatch WHERE (household_id,purchaser_id)=(OLD.household_id,OLD.member_id);
 DELETE FROM ritc.renewal_contact WHERE (household_id,purchaser_id)=(OLD.household_id,OLD.member_id);
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ritc.forget_renewal_member() FROM PUBLIC;
CREATE TRIGGER forget_renewal_member AFTER UPDATE OF state,erased_at,issuer,subject ON ritc.member
 FOR EACH ROW WHEN (OLD.state IS DISTINCT FROM NEW.state OR OLD.erased_at IS DISTINCT FROM NEW.erased_at
 OR OLD.issuer IS DISTINCT FROM NEW.issuer OR OLD.subject IS DISTINCT FROM NEW.subject) EXECUTE FUNCTION ritc.forget_renewal_member();

-- An old backup cannot establish current consent or the final outcome of an interrupted email.
CREATE FUNCTION ritc.forget_restored_renewal_contacts() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog SET row_security=off AS $$
BEGIN
 IF ritc.is_final_restore_segment(NEW.run_id) THEN
  PERFORM pg_advisory_xact_lock(hashtextextended('ritc.renewal_restore_fence',0));
  INSERT INTO ritc.renewal_restore_fence VALUES(true,clock_timestamp())
  ON CONFLICT(singleton) DO UPDATE SET restored_at=greatest(ritc.renewal_restore_fence.restored_at,excluded.restored_at);
  DELETE FROM ritc.renewal_contact;
  -- Preserve bounded dispatch evidence to prevent a replay after re-enrollment.
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ritc.forget_restored_renewal_contacts() FROM PUBLIC;
CREATE TRIGGER forget_restored_renewal_contacts AFTER UPDATE OF phase ON ritc.privacy_restore_run
 FOR EACH ROW WHEN (NEW.phase='local_app_erased' AND OLD.phase IS DISTINCT FROM NEW.phase)
 EXECUTE FUNCTION ritc.forget_restored_renewal_contacts();


-- Invalidate consent on a provider-side change even if the original address is later restored.
-- The provider table is not present on every offline migration/restore fixture.
CREATE FUNCTION ritc.forget_changed_renewal_address() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog SET row_security=off AS $$
DECLARE ignored text;
BEGIN
 IF TG_OP='UPDATE' AND lower(trim(OLD.email)) IS NOT DISTINCT FROM lower(trim(NEW.email))
    AND OLD.email_confirmed_at IS NOT DISTINCT FROM NEW.email_confirmed_at THEN RETURN NEW; END IF;
 IF TG_OP='DELETE' THEN
  DELETE FROM ritc.renewal_dispatch e USING ritc.member m
   WHERE (m.household_id,m.member_id)=(e.household_id,e.purchaser_id) AND m.subject=OLD.id::text;
 END IF;
 WITH lost AS (
  DELETE FROM ritc.renewal_contact c USING ritc.member m
   WHERE (m.household_id,m.member_id)=(c.household_id,c.purchaser_id) AND m.subject=OLD.id::text RETURNING c.original_id
 ) SELECT ritc.note_renewal_route_loss(count(original_id)) INTO ignored FROM lost;
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION ritc.forget_changed_renewal_address() FROM PUBLIC;
DO $$ BEGIN
 IF to_regclass('auth.users') IS NOT NULL THEN
  CREATE TRIGGER forget_changed_renewal_address AFTER UPDATE OF email,email_confirmed_at OR DELETE ON auth.users
   FOR EACH ROW EXECUTE FUNCTION ritc.forget_changed_renewal_address();
 END IF;
END $$;

CREATE FUNCTION ritc.renewal_housekeeping(prune boolean) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog SET row_security=off AS $$
BEGIN
 IF prune THEN
  DELETE FROM ritc.renewal_dispatch WHERE purge_at<=now();
  DELETE FROM ritc.renewal_contact WHERE original_id IS NULL AND enrolled_at<=now()-interval '30 days';
  DELETE FROM ritc.renewal_contact c WHERE c.original_id IS NOT NULL AND NOT EXISTS(
   SELECT 1 FROM ritc.billing_state b WHERE (b.household_id,b.purchaser_id)=(c.household_id,c.purchaser_id)
   AND b.subscription->>'originalTransactionID'=c.original_id AND b.subscription->>'environment'='Production'
   AND b.subscription->>'mxAnnual'='true' AND b.subscription->>'status'='active'
   AND to_timestamp((b.subscription->>'expiresAt')::double precision/1000)>now());
  DELETE FROM ritc.renewal_route_loss WHERE day<=(now() AT TIME ZONE 'UTC')::date-30;
 END IF;
 RETURN (SELECT coalesce(sum(count),0) FROM ritc.renewal_route_loss WHERE day=(now() AT TIME ZONE 'UTC')::date);
END $$;
REVOKE ALL ON FUNCTION ritc.renewal_housekeeping(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.renewal_housekeeping(boolean) TO ritc_worker;
