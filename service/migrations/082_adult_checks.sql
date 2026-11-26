-- One explicitly selected item or dinner. Source wording stays in the existing shop.
CREATE TABLE ritc.adult_check (
  household_id uuid NOT NULL, shop_id uuid NOT NULL, check_id uuid NOT NULL,
  shopper_id uuid NOT NULL, recipient_id uuid NOT NULL CHECK (recipient_id <> shopper_id),
  shop_revision integer NOT NULL, authority_epoch integer NOT NULL, pair_revision integer NOT NULL,
  kind text NOT NULL CHECK (kind IN ('attendance','cupboard')), source_id uuid NOT NULL,
  created_at timestamptz NOT NULL, expires_at timestamptz NOT NULL,
  answer text, quantity jsonb, answered_at timestamptz,
  reviewed boolean NOT NULL DEFAULT false, withdrawn boolean NOT NULL DEFAULT false,
  PRIMARY KEY (household_id,shop_id,check_id),
  FOREIGN KEY (household_id,shop_id) REFERENCES ritc.shop ON DELETE CASCADE,
  FOREIGN KEY (household_id,shopper_id) REFERENCES ritc.billing_seat(household_id,member_id) ON DELETE CASCADE,
  FOREIGN KEY (household_id,recipient_id) REFERENCES ritc.billing_seat(household_id,member_id) ON DELETE CASCADE,
  CHECK (expires_at > created_at AND expires_at <= created_at + interval '168 hours'),
  CHECK ((answer IS NULL) = (answered_at IS NULL)),
  CHECK (answer IS NULL OR (kind='attendance' AND answer IN ('home','latePlate','out'))
    OR (kind='cupboard' AND answer IN ('enough','low','cannotCheck'))),
  CHECK (quantity IS NULL OR (answer IS NOT NULL AND answer IN ('enough','low') AND jsonb_typeof(quantity)='object')),
  CHECK (NOT reviewed OR answer IS NOT NULL)
);
CREATE INDEX adult_check_expiry ON ritc.adult_check(expires_at);
ALTER TABLE ritc.adult_check ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.adult_check FORCE ROW LEVEL SECURITY;
CREATE POLICY participants ON ritc.adult_check TO ritc_app
USING (expires_at>statement_timestamp() AND household_id::text=(SELECT current_setting('app.household_id',true)) AND
  (SELECT current_setting('app.content_viewer',true)) IN (shopper_id::text,recipient_id::text))
WITH CHECK (household_id::text=(SELECT current_setting('app.household_id',true)) AND
  (SELECT current_setting('app.content_viewer',true)) IN (shopper_id::text,recipient_id::text));
GRANT SELECT,INSERT,UPDATE ON ritc.adult_check TO ritc_app;

-- Retiring either named seat already cascades through the two foreign keys.
-- A verified loss of paid status also retires the pair's outstanding facts.
CREATE FUNCTION ritc.clear_unpaid_adult_checks() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  DELETE FROM ritc.adult_check WHERE household_id=NEW.household_id;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION ritc.clear_unpaid_adult_checks() FROM PUBLIC;
CREATE TRIGGER clear_unpaid_adult_checks AFTER UPDATE OF subscription ON ritc.billing_state
  FOR EACH ROW WHEN (NEW.subscription->>'status' IN ('revoked','expired','billingRetry'))
  EXECUTE FUNCTION ritc.clear_unpaid_adult_checks();

-- Reuse the existing bounded maintenance pass. Expiry already denies reads.
ALTER FUNCTION ritc.maintenance_prepare_auth(integer) RENAME TO maintenance_prepare_before_adult_checks;
REVOKE ALL ON FUNCTION ritc.maintenance_prepare_before_adult_checks(integer) FROM ritc_worker;
CREATE FUNCTION ritc.maintenance_prepare_auth(batch_size integer)
RETURNS TABLE(expired_queued integer,emails_cleared integer,auth_purged integer,rates_purged integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  WITH expired AS (
    SELECT household_id,shop_id,check_id FROM ritc.adult_check WHERE expires_at<=statement_timestamp()
    ORDER BY expires_at FOR UPDATE SKIP LOCKED LIMIT greatest(1,least(batch_size,100))
  )
  DELETE FROM ritc.adult_check a USING expired e
  WHERE (a.household_id,a.shop_id,a.check_id)=(e.household_id,e.shop_id,e.check_id);
  RETURN QUERY SELECT * FROM ritc.maintenance_prepare_before_adult_checks(batch_size);
END $$;
REVOKE ALL ON FUNCTION ritc.maintenance_prepare_auth(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.maintenance_prepare_auth(integer) TO ritc_worker;
