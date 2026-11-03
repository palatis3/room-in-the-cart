-- Optional measurement has its own consent, identities and code-only records.
-- No local grocery record or Apple receipt can create measurement consent.
ALTER TABLE ritc.shop ADD COLUMN measurement_closed_at timestamptz;
CREATE FUNCTION ritc.measurement_close_time() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='INSERT' THEN
  NEW.measurement_closed_at=CASE WHEN NEW.phase='closed' THEN clock_timestamp() ELSE NULL END;
 ELSIF OLD.phase<>'closed' AND NEW.phase='closed' THEN
  NEW.measurement_closed_at=clock_timestamp();
 ELSE NEW.measurement_closed_at=OLD.measurement_closed_at;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER measurement_close_time BEFORE INSERT OR UPDATE ON ritc.shop FOR EACH ROW EXECUTE FUNCTION ritc.measurement_close_time();
-- Existing closed shops intentionally retain NULL: their eligible week is unknown.
CREATE TABLE ritc.measurement_consent (
 household_id uuid NOT NULL,consent_id uuid NOT NULL,member_id uuid NOT NULL,
 notice_version text NOT NULL CHECK(notice_version='pickup-feedback-2026-11-03.v1'),
 granted_at timestamptz NOT NULL,withdrawn_at timestamptz,
 PRIMARY KEY(household_id,consent_id),
 UNIQUE(household_id,consent_id,member_id,notice_version),
 FOREIGN KEY(household_id,member_id) REFERENCES ritc.member,
 CHECK(withdrawn_at IS NULL OR withdrawn_at>=granted_at)
);
CREATE UNIQUE INDEX measurement_current_consent ON ritc.measurement_consent(household_id,member_id) WHERE withdrawn_at IS NULL;
CREATE TABLE ritc.measurement_feedback (
 household_id uuid NOT NULL,feedback_id uuid NOT NULL,shop_id uuid NOT NULL,
 eligible_week text NOT NULL CHECK(eligible_week ~ '^[0-9]{4}-W(0[1-9]|[1-4][0-9]|5[0-3])$'),
 consent_id uuid NOT NULL,member_id uuid NOT NULL,consent_version text NOT NULL,
 outcome text NOT NULL CHECK(outcome IN ('acted','unchanged','late','unknown','already_knew','wrong')),
 baseline text NOT NULL CHECK(baseline IN ('retailer','list','usualRoutine','unknown')),
 comparison text NOT NULL CHECK(comparison IN ('same','different','unknown')),
 recorded_at timestamptz NOT NULL,
 PRIMARY KEY(household_id,feedback_id),UNIQUE(household_id,shop_id,eligible_week),
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,
 FOREIGN KEY(household_id,consent_id,member_id,consent_version) REFERENCES ritc.measurement_consent(household_id,consent_id,member_id,notice_version)
);
CREATE FUNCTION ritc.measurement_consent_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF (NEW.household_id,NEW.consent_id,NEW.member_id,NEW.notice_version,NEW.granted_at) IS DISTINCT FROM
    (OLD.household_id,OLD.consent_id,OLD.member_id,OLD.notice_version,OLD.granted_at)
    OR (OLD.withdrawn_at IS NOT NULL AND NEW.withdrawn_at IS DISTINCT FROM OLD.withdrawn_at) THEN
  RAISE EXCEPTION 'measurement consent requires a fresh explicit action' USING ERRCODE='23514';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER measurement_consent_immutable BEFORE UPDATE ON ritc.measurement_consent FOR EACH ROW EXECUTE FUNCTION ritc.measurement_consent_immutable();
CREATE FUNCTION ritc.measurement_feedback_eligible() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM ritc.measurement_consent c JOIN ritc.member m USING(household_id,member_id)
  JOIN ritc.shop s ON s.household_id=c.household_id AND s.shop_id=NEW.shop_id AND s.shopper_id=c.member_id
  WHERE c.household_id=NEW.household_id AND c.consent_id=NEW.consent_id AND c.member_id=NEW.member_id
  AND c.notice_version=NEW.consent_version AND c.withdrawn_at IS NULL AND m.kind='adult' AND m.state='active'
  AND s.phase='closed' AND s.placed_revision IS NOT NULL AND s.measurement_closed_at IS NOT NULL
  AND NEW.eligible_week=to_char(s.measurement_closed_at AT TIME ZONE 'UTC','IYYY-"W"IW')) THEN
  RAISE EXCEPTION 'current consent and eligible shared pickup required' USING ERRCODE='23514';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER measurement_feedback_eligible BEFORE INSERT ON ritc.measurement_feedback FOR EACH ROW EXECUTE FUNCTION ritc.measurement_feedback_eligible();
DO $$ DECLARE item text;BEGIN FOREACH item IN ARRAY ARRAY['measurement_consent','measurement_feedback'] LOOP
 EXECUTE format('ALTER TABLE ritc.%I ENABLE ROW LEVEL SECURITY',item);EXECUTE format('ALTER TABLE ritc.%I FORCE ROW LEVEL SECURITY',item);
 EXECUTE format('CREATE POLICY tenant_scope ON ritc.%I USING(household_id::text=(SELECT current_setting(''app.household_id'',true))) WITH CHECK(household_id::text=(SELECT current_setting(''app.household_id'',true)))',item);
 EXECUTE format('GRANT SELECT,INSERT ON ritc.%I TO ritc_app',item);
END LOOP;END $$;
GRANT UPDATE(withdrawn_at) ON ritc.measurement_consent TO ritc_app;
GRANT DELETE ON ritc.measurement_feedback TO ritc_app;
-- A live projection, not an incrementing sale counter. One billing_state row is one
-- canonical household across devices, deliveries, restores, seats and renewals.
-- Refund/revocation and expiry remove retention immediately; Sandbox is never a buyer.
CREATE VIEW ritc.measurement_willing_household WITH (security_invoker=true) AS
 SELECT b.household_id,
  CASE WHEN b.subscription->>'status'='active' THEN 'active' ELSE 'grace' END AS billing_status
 FROM ritc.billing_state b
 WHERE b.subscription->>'environment'='Production'
 AND ((b.subscription->>'status'='active' AND (b.subscription->>'expiresAt')::numeric>extract(epoch FROM clock_timestamp())*1000)
   OR (b.subscription->>'status'='grace' AND (b.subscription->>'graceExpiresAt')::numeric>extract(epoch FROM clock_timestamp())*1000))
 AND EXISTS(SELECT 1 FROM ritc.measurement_consent c JOIN ritc.member m USING(household_id,member_id)
  WHERE c.household_id=b.household_id AND c.withdrawn_at IS NULL AND c.notice_version='pickup-feedback-2026-11-03.v1' AND m.kind='adult' AND m.state='active');
GRANT SELECT ON ritc.measurement_willing_household TO ritc_app;
-- The erasure worker already changes the member to its de-identified tombstone.
-- Use that established boundary so later extensions cannot omit measurement cleanup.
CREATE FUNCTION ritc.measurement_member_erasure() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF OLD.erased_at IS NULL AND NEW.erased_at IS NOT NULL THEN
  DELETE FROM ritc.measurement_feedback WHERE household_id=NEW.household_id AND member_id=NEW.member_id;
  DELETE FROM ritc.measurement_consent WHERE household_id=NEW.household_id AND member_id=NEW.member_id;
 ELSIF OLD.state='active' AND NEW.state<>'active' THEN
  DELETE FROM ritc.measurement_feedback WHERE household_id=NEW.household_id AND member_id=NEW.member_id;
  UPDATE ritc.measurement_consent SET withdrawn_at=GREATEST(clock_timestamp(),granted_at) WHERE household_id=NEW.household_id AND member_id=NEW.member_id AND withdrawn_at IS NULL;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER measurement_member_erasure AFTER UPDATE ON ritc.member FOR EACH ROW EXECUTE FUNCTION ritc.measurement_member_erasure();
