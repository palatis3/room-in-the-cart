-- PostgreSQL 17+. Private schema: never expose it through PostgREST/browser DB clients.
CREATE SCHEMA IF NOT EXISTS ritc;
REVOKE ALL ON SCHEMA ritc FROM PUBLIC;
CREATE TABLE ritc.household (
  household_id uuid PRIMARY KEY, label text NOT NULL CHECK(length(label) BETWEEN 1 AND 80), created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE ritc.member (
  household_id uuid NOT NULL REFERENCES ritc.household, member_id uuid NOT NULL,
  issuer text NOT NULL, subject text NOT NULL, alias text NOT NULL CHECK (length(alias) BETWEEN 1 AND 80),
  kind text NOT NULL CHECK (kind IN ('adult','child')),
  state text NOT NULL CHECK (state IN ('active','revoked')),
  organizer boolean NOT NULL DEFAULT false, can_contribute boolean NOT NULL DEFAULT false,
  PRIMARY KEY (household_id,member_id), UNIQUE (household_id,issuer,subject),
  CHECK (NOT organizer OR kind='adult')
);
CREATE TABLE ritc.guardian_relationship (
  household_id uuid NOT NULL, child_id uuid NOT NULL, guardian_id uuid NOT NULL,
  proof_ref text NOT NULL CHECK (length(proof_ref)>0), revoked_at timestamptz,
  PRIMARY KEY (household_id,child_id,guardian_id), CHECK (child_id<>guardian_id),
  FOREIGN KEY(household_id,child_id) REFERENCES ritc.member,
  FOREIGN KEY(household_id,guardian_id) REFERENCES ritc.member
);
CREATE TABLE ritc.consent (
  household_id uuid NOT NULL, consent_id uuid NOT NULL, child_id uuid NOT NULL, guardian_id uuid NOT NULL,
  notice_version text NOT NULL CHECK (length(notice_version)>0),
  verification_ref text NOT NULL CHECK (length(verification_ref)>0),
  granted_at timestamptz NOT NULL DEFAULT now(), revoked_at timestamptz,
  PRIMARY KEY(household_id,consent_id),
  FOREIGN KEY(household_id,child_id,guardian_id) REFERENCES ritc.guardian_relationship
);
CREATE INDEX consent_live_child ON ritc.consent(household_id,child_id) WHERE revoked_at IS NULL;
CREATE TABLE ritc.device (
  household_id uuid NOT NULL, device_id uuid NOT NULL, member_id uuid NOT NULL,
  token_hash text NOT NULL CHECK(length(token_hash)=64), session_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(), revoked_at timestamptz,
  PRIMARY KEY(household_id,device_id), UNIQUE(household_id,token_hash),
  UNIQUE(household_id,member_id,device_id), FOREIGN KEY(household_id,member_id) REFERENCES ritc.member
);
CREATE TABLE ritc.replay_window (
  household_id uuid NOT NULL, window_id uuid NOT NULL, member_id uuid NOT NULL, device_id uuid NOT NULL,
  issued_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz NOT NULL, revoked_at timestamptz,
  PRIMARY KEY(household_id,window_id),
  FOREIGN KEY(household_id,member_id,device_id) REFERENCES ritc.device(household_id,member_id,device_id),
  CHECK(expires_at>issued_at)
);
CREATE INDEX replay_device ON ritc.replay_window(household_id,device_id);
CREATE TABLE ritc.shop (
  household_id uuid NOT NULL, shop_id uuid NOT NULL, shopper_id uuid NOT NULL,
  authority_epoch integer NOT NULL DEFAULT 1 CHECK(authority_epoch>0),
  revision integer NOT NULL DEFAULT 1 CHECK(revision>0),
  phase text NOT NULL DEFAULT 'draft' CHECK(phase IN ('draft','frozen','placed','closed')),
  quote jsonb NOT NULL, frozen_revision integer, placed_revision integer,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(household_id,shop_id), FOREIGN KEY(household_id,shopper_id) REFERENCES ritc.member
);
CREATE TABLE ritc.shop_authority (
  household_id uuid NOT NULL, shop_id uuid NOT NULL, epoch integer NOT NULL CHECK(epoch>0), member_id uuid NOT NULL,
  granted_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(household_id,shop_id,epoch), FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,
  FOREIGN KEY(household_id,member_id) REFERENCES ritc.member
);
CREATE TABLE ritc.basket_line (
  household_id uuid NOT NULL, shop_id uuid NOT NULL, line_id uuid NOT NULL,
  original_item text NOT NULL CHECK(length(original_item) BETWEEN 1 AND 240),
  packs integer NOT NULL CHECK(packs BETWEEN 1 AND 10000), fee_eligible boolean NOT NULL,
  unit_price_minor bigint CHECK(unit_price_minor BETWEEN 0 AND 1000000000),
  PRIMARY KEY(household_id,shop_id,line_id), FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop
);
CREATE TABLE ritc.request (
  household_id uuid NOT NULL, request_id uuid NOT NULL, author_id uuid NOT NULL, client_request_id uuid NOT NULL,
  shop_id uuid NOT NULL, original_item text NOT NULL CHECK(length(original_item) BETWEEN 1 AND 240),
  own_quantity text CHECK(length(own_quantity)<=80), revision integer NOT NULL DEFAULT 1 CHECK(revision>0),
  route text NOT NULL CHECK(route IN ('current','next')),
  status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','clarified','added','deferred','handled','dismissed','withdrawn')),
  authored_at timestamptz NOT NULL, received_at timestamptz NOT NULL DEFAULT now(),
  clarification text CHECK(length(clarification)<=300), followup_to uuid,
  PRIMARY KEY(household_id,request_id), UNIQUE(household_id,author_id,client_request_id),
  FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,
  FOREIGN KEY(household_id,author_id) REFERENCES ritc.member,
  FOREIGN KEY(household_id,followup_to) REFERENCES ritc.request
);
CREATE INDEX request_own_page ON ritc.request(household_id,author_id,received_at,request_id);
CREATE INDEX request_shop_page ON ritc.request(household_id,shop_id,received_at,request_id);
CREATE TABLE ritc.operation (
  household_id uuid NOT NULL, operation_id uuid NOT NULL, actor_id uuid NOT NULL, device_id uuid NOT NULL,
  client_key uuid NOT NULL, window_id uuid NOT NULL, kind text NOT NULL, shop_id uuid NOT NULL,
  payload_digest text NOT NULL CHECK(length(payload_digest)=64),
  response_scope text NOT NULL CHECK(response_scope IN ('own','shopper','organizer','reporter')),
  committed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(household_id,operation_id), UNIQUE(household_id,actor_id,client_key),
  FOREIGN KEY(household_id,actor_id,device_id) REFERENCES ritc.device(household_id,member_id,device_id),
  FOREIGN KEY(household_id,window_id) REFERENCES ritc.replay_window,
  FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop
);
CREATE TABLE ritc.operation_response (
  household_id uuid NOT NULL, operation_id uuid NOT NULL, response jsonb NOT NULL,
  PRIMARY KEY(household_id,operation_id), FOREIGN KEY(household_id,operation_id) REFERENCES ritc.operation
);
CREATE TABLE ritc.request_link (
  household_id uuid NOT NULL, request_id uuid NOT NULL, shop_id uuid NOT NULL, line_id uuid NOT NULL,
  reviewed_revision integer NOT NULL, operation_id uuid NOT NULL,
  PRIMARY KEY(household_id,request_id), FOREIGN KEY(household_id,request_id) REFERENCES ritc.request,
  FOREIGN KEY(household_id,shop_id,line_id) REFERENCES ritc.basket_line,
  FOREIGN KEY(household_id,operation_id) REFERENCES ritc.operation DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE ritc.preview (
  household_id uuid NOT NULL, preview_id uuid NOT NULL, shop_id uuid NOT NULL, actor_id uuid NOT NULL,
  request_id uuid NOT NULL, shop_revision integer NOT NULL, request_revision integer NOT NULL, authority_epoch integer NOT NULL,
  decision jsonb NOT NULL, fingerprint text NOT NULL, expires_at timestamptz NOT NULL,
  PRIMARY KEY(household_id,preview_id), FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,
  FOREIGN KEY(household_id,request_id) REFERENCES ritc.request, FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member
);
CREATE TABLE ritc.shop_snapshot (
  household_id uuid NOT NULL, shop_id uuid NOT NULL, revision integer NOT NULL,
  purpose text NOT NULL CHECK(purpose IN ('create','patch','decision','freeze','reopen','placed')),
  snapshot jsonb NOT NULL, digest text NOT NULL CHECK(length(digest)=64),
  operation_id uuid NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(household_id,shop_id,revision), FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,
  FOREIGN KEY(household_id,operation_id) REFERENCES ritc.operation DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE ritc.placement_report (
  household_id uuid NOT NULL, report_id uuid NOT NULL, shop_id uuid NOT NULL, actor_id uuid NOT NULL,
  reported_epoch integer NOT NULL, reported_revision integer NOT NULL,
  occurred_at timestamptz NOT NULL, received_at timestamptz NOT NULL DEFAULT now(),
  source text NOT NULL DEFAULT 'shopper_reported' CHECK(source='shopper_reported'),
  state text NOT NULL CHECK(state IN ('pending_reconciliation','applied','rejected')),
  operation_id uuid NOT NULL, resolution_operation_id uuid,
  PRIMARY KEY(household_id,report_id), FOREIGN KEY(household_id,shop_id,reported_epoch) REFERENCES ritc.shop_authority,
  FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member,
  FOREIGN KEY(household_id,shop_id,reported_revision) REFERENCES ritc.shop_snapshot,
  FOREIGN KEY(household_id,operation_id) REFERENCES ritc.operation DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY(household_id,resolution_operation_id) REFERENCES ritc.operation DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE ritc.event (
  event_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  household_id uuid NOT NULL, operation_id uuid NOT NULL, shop_id uuid NOT NULL, kind text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY(household_id,operation_id) REFERENCES ritc.operation DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop
);
CREATE INDEX event_tenant_cursor ON ritc.event(household_id,event_id);
-- Durable snapshots, operations and evidence are never mutable through the runtime role.
CREATE FUNCTION ritc.immutable_row() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'immutable evidence' USING ERRCODE='23514'; END $$;
CREATE TRIGGER snapshot_immutable BEFORE UPDATE OR DELETE ON ritc.shop_snapshot FOR EACH ROW EXECUTE FUNCTION ritc.immutable_row();
CREATE TRIGGER operation_immutable BEFORE UPDATE OR DELETE ON ritc.operation FOR EACH ROW EXECUTE FUNCTION ritc.immutable_row();
CREATE TRIGGER authority_immutable BEFORE UPDATE OR DELETE ON ritc.shop_authority FOR EACH ROW EXECUTE FUNCTION ritc.immutable_row();
-- Serialize access changes with all household commands, including changes made by provisioning jobs.
CREATE FUNCTION ritc.lock_household_access() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM ritc.household WHERE household_id=OLD.household_id FOR UPDATE;
  RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $$;
CREATE TRIGGER member_access_lock BEFORE UPDATE OR DELETE ON ritc.member FOR EACH ROW EXECUTE FUNCTION ritc.lock_household_access();
CREATE TRIGGER consent_access_lock BEFORE UPDATE OR DELETE ON ritc.consent FOR EACH ROW EXECUTE FUNCTION ritc.lock_household_access();
CREATE TRIGGER relationship_access_lock BEFORE UPDATE OR DELETE ON ritc.guardian_relationship FOR EACH ROW EXECUTE FUNCTION ritc.lock_household_access();
CREATE TRIGGER device_access_lock BEFORE UPDATE OR DELETE ON ritc.device FOR EACH ROW EXECUTE FUNCTION ritc.lock_household_access();
CREATE FUNCTION ritc.consent_revoke_once() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.revoked_at IS NOT NULL OR NEW.revoked_at IS NULL OR
    (to_jsonb(NEW)-'revoked_at') IS DISTINCT FROM (to_jsonb(OLD)-'revoked_at') THEN
    RAISE EXCEPTION 'consent can only be revoked once; new evidence required' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER consent_immutable BEFORE UPDATE ON ritc.consent FOR EACH ROW EXECUTE FUNCTION ritc.consent_revoke_once();
DO $$ DECLARE item record; BEGIN
  FOR item IN SELECT tablename FROM pg_tables WHERE schemaname='ritc' LOOP
    EXECUTE format('ALTER TABLE ritc.%I ENABLE ROW LEVEL SECURITY',item.tablename);
    EXECUTE format('ALTER TABLE ritc.%I FORCE ROW LEVEL SECURITY',item.tablename);
    EXECUTE format('CREATE POLICY tenant_scope ON ritc.%I USING (household_id::text=current_setting(''app.household_id'',true)) WITH CHECK (household_id::text=current_setting(''app.household_id'',true))',item.tablename);
  END LOOP;
END $$;
DO $$ BEGIN
  IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='ritc_app') THEN CREATE ROLE ritc_app NOLOGIN NOSUPERUSER NOBYPASSRLS; END IF;
END $$;
GRANT USAGE ON SCHEMA ritc TO ritc_app;
GRANT SELECT ON ALL TABLES IN SCHEMA ritc TO ritc_app;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA ritc TO ritc_app;
GRANT INSERT ON ritc.device,ritc.replay_window,ritc.shop,ritc.shop_authority,ritc.basket_line,ritc.request,ritc.operation,ritc.operation_response,ritc.request_link,ritc.preview,ritc.shop_snapshot,ritc.placement_report,ritc.event TO ritc_app;
GRANT UPDATE ON ritc.device,ritc.replay_window,ritc.shop,ritc.basket_line,ritc.request,ritc.placement_report TO ritc_app;
GRANT DELETE ON ritc.basket_line TO ritc_app;

-- Authenticated service can discover only memberships of its verified issuer/subject.
CREATE POLICY own_membership_lookup ON ritc.member FOR SELECT USING (
 issuer=current_setting('app.issuer',true) AND subject=current_setting('app.subject',true) AND state='active');
CREATE POLICY own_household_lookup ON ritc.household FOR SELECT USING (EXISTS(
 SELECT 1 FROM ritc.member m WHERE m.household_id=household.household_id
 AND m.issuer=current_setting('app.issuer',true) AND m.subject=current_setting('app.subject',true) AND m.state='active'));
