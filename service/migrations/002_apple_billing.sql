-- Apple purchase binding is independent of shop authority and household data grants.
CREATE TABLE ritc.billing_account (
  household_id uuid NOT NULL, purchaser_id uuid NOT NULL,
  app_account_token uuid NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(household_id,purchaser_id),
  UNIQUE(household_id,purchaser_id,app_account_token),
  FOREIGN KEY(household_id,purchaser_id) REFERENCES ritc.member
);
CREATE TABLE ritc.billing_binding (
  environment text NOT NULL CHECK(environment IN ('Production','Sandbox')),
  original_transaction_id text NOT NULL CHECK(original_transaction_id ~ '^[0-9]{1,64}$'),
  household_id uuid NOT NULL, purchaser_id uuid NOT NULL, app_account_token uuid NOT NULL,
  bound_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(environment,original_transaction_id),
  FOREIGN KEY(household_id,purchaser_id,app_account_token) REFERENCES ritc.billing_account(household_id,purchaser_id,app_account_token),
  UNIQUE(environment,original_transaction_id,household_id,purchaser_id)
);
CREATE TABLE ritc.billing_state (
  household_id uuid PRIMARY KEY REFERENCES ritc.household,
  purchaser_id uuid NOT NULL, revision integer NOT NULL DEFAULT 1 CHECK(revision>0),
  subscription jsonb NOT NULL CHECK(jsonb_typeof(subscription)='object'),
  verified_at timestamptz NOT NULL,
  FOREIGN KEY(household_id,purchaser_id) REFERENCES ritc.billing_account
);
CREATE TABLE ritc.billing_seat (
  household_id uuid NOT NULL REFERENCES ritc.billing_state,
  slot smallint NOT NULL CHECK(slot IN (1,2)), member_id uuid NOT NULL,
  display_name text NOT NULL CHECK(length(display_name) BETWEEN 1 AND 80),
  PRIMARY KEY(household_id,slot), UNIQUE(household_id,member_id),
  FOREIGN KEY(household_id,member_id) REFERENCES ritc.member
);
CREATE TABLE ritc.billing_delivery (
  environment text NOT NULL CHECK(environment IN ('Production','Sandbox')),
  transaction_id text NOT NULL CHECK(transaction_id ~ '^[0-9]{1,64}$'),
  household_id uuid NOT NULL, purchaser_id uuid NOT NULL,
  original_transaction_id text NOT NULL,
  accepted_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(environment,transaction_id),
  FOREIGN KEY(environment,original_transaction_id,household_id,purchaser_id) REFERENCES ritc.billing_binding(environment,original_transaction_id,household_id,purchaser_id),
  FOREIGN KEY(household_id,purchaser_id) REFERENCES ritc.billing_account
);
CREATE TABLE ritc.billing_event (
  household_id uuid NOT NULL REFERENCES ritc.household,
  event_id uuid NOT NULL, kind text NOT NULL CHECK(kind IN ('verified','seats_changed','notification')),
  event_key text NOT NULL CHECK(length(event_key)<=200),
  actor_id uuid, revision integer NOT NULL CHECK(revision>0),
  occurred_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(household_id,event_id), UNIQUE(household_id,kind,event_key)
);
DO $$ DECLARE name text; BEGIN
  FOREACH name IN ARRAY ARRAY['billing_account','billing_binding','billing_state','billing_seat','billing_delivery','billing_event'] LOOP
    EXECUTE format('ALTER TABLE ritc.%I ENABLE ROW LEVEL SECURITY',name);
    EXECUTE format('ALTER TABLE ritc.%I FORCE ROW LEVEL SECURITY',name);
    EXECUTE format('CREATE POLICY tenant_scope ON ritc.%I USING(household_id::text=current_setting(''app.household_id'',true)) WITH CHECK(household_id::text=current_setting(''app.household_id'',true))',name);
  END LOOP;
  FOREACH name IN ARRAY ARRAY['billing_account','billing_binding','billing_delivery','billing_event'] LOOP
    EXECUTE format('CREATE TRIGGER evidence_immutable BEFORE UPDATE OR DELETE ON ritc.%I FOR EACH ROW EXECUTE FUNCTION ritc.immutable_row()',name);
  END LOOP;
END $$;
-- Only a cryptographically verified Apple notification may set app.billing_token in application code.
-- This reveals the one routing record, never a cross-household subscription or family roster.
CREATE POLICY verified_apple_notification_route ON ritc.billing_account FOR SELECT
  USING(app_account_token::text=current_setting('app.billing_token',true));
CREATE FUNCTION ritc.billing_adult_seat() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM ritc.member WHERE household_id=NEW.household_id AND member_id=NEW.member_id AND kind='adult' AND state='active') THEN
    RAISE EXCEPTION 'billing seats require active adults' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER adult_billing_seat BEFORE INSERT OR UPDATE ON ritc.billing_seat FOR EACH ROW EXECUTE FUNCTION ritc.billing_adult_seat();
GRANT SELECT,INSERT ON ritc.billing_account,ritc.billing_binding,ritc.billing_state,ritc.billing_seat,ritc.billing_delivery,ritc.billing_event TO ritc_app;
GRANT UPDATE ON ritc.billing_state TO ritc_app;
GRANT DELETE ON ritc.billing_seat TO ritc_app;
