-- Self-serve adult enrollment; child consent proof remains a server-only provider concern.
CREATE TABLE ritc.household_creation (
  issuer text NOT NULL, subject text NOT NULL, client_key uuid NOT NULL, household_id uuid NOT NULL REFERENCES ritc.household,
  member_id uuid NOT NULL, payload_digest text NOT NULL, PRIMARY KEY(issuer,subject,client_key),
  FOREIGN KEY(household_id,member_id) REFERENCES ritc.member
);
ALTER TABLE ritc.household_creation ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.household_creation FORCE ROW LEVEL SECURITY;
CREATE POLICY own_creation ON ritc.household_creation USING(issuer=(SELECT current_setting('app.issuer',true)) AND subject=(SELECT current_setting('app.subject',true))) WITH CHECK(issuer=(SELECT current_setting('app.issuer',true)) AND subject=(SELECT current_setting('app.subject',true)));
CREATE INDEX household_creation_member ON ritc.household_creation(household_id,member_id);
CREATE TABLE ritc.view_grant (
 household_id uuid NOT NULL, grant_id uuid NOT NULL, shop_id uuid NOT NULL, created_by uuid NOT NULL,
 recipient_id uuid, mode text NOT NULL CHECK(mode IN ('read','edit')), revision integer NOT NULL DEFAULT 1 CHECK(revision>0),
 projection jsonb NOT NULL, as_of timestamptz NOT NULL DEFAULT now(), expires_at timestamptz NOT NULL, revoked_at timestamptz,
 PRIMARY KEY(household_id,grant_id), FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,
 FOREIGN KEY(household_id,created_by) REFERENCES ritc.member, FOREIGN KEY(household_id,recipient_id) REFERENCES ritc.member
);
CREATE INDEX view_grant_shop ON ritc.view_grant(household_id,shop_id);
CREATE INDEX view_grant_creator ON ritc.view_grant(household_id,created_by);
CREATE INDEX view_grant_recipient ON ritc.view_grant(household_id,recipient_id);
CREATE TABLE ritc.invite (
 household_id uuid NOT NULL, invite_id uuid NOT NULL, token_hash text NOT NULL CHECK(length(token_hash)=64),
 kind text NOT NULL CHECK(kind IN ('adult_contributor','helper_read','helper_edit')), created_by uuid NOT NULL,
 grant_id uuid, expires_at timestamptz NOT NULL, redeemed_at timestamptz, redeemed_by uuid, revoked_at timestamptz,
 PRIMARY KEY(household_id,invite_id), UNIQUE(household_id,token_hash),
 FOREIGN KEY(household_id,created_by) REFERENCES ritc.member, FOREIGN KEY(household_id,redeemed_by) REFERENCES ritc.member,
 FOREIGN KEY(household_id,grant_id) REFERENCES ritc.view_grant,
 CHECK((kind='adult_contributor')=(grant_id IS NULL))
);
CREATE INDEX invite_creator ON ritc.invite(household_id,created_by);
CREATE INDEX invite_recipient ON ritc.invite(household_id,redeemed_by);
CREATE INDEX invite_grant ON ritc.invite(household_id,grant_id);
CREATE TABLE ritc.helper_proposal (
 household_id uuid NOT NULL, proposal_id uuid NOT NULL, grant_id uuid NOT NULL, actor_id uuid NOT NULL,
 client_key uuid NOT NULL, base_revision integer NOT NULL CHECK(base_revision>0), correction text NOT NULL CHECK(length(correction) BETWEEN 1 AND 1000),
 payload_digest text NOT NULL, status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','reviewed','dismissed')),
 created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(household_id,proposal_id), UNIQUE(household_id,actor_id,client_key),
 FOREIGN KEY(household_id,grant_id) REFERENCES ritc.view_grant, FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member
);
CREATE INDEX helper_proposal_grant ON ritc.helper_proposal(household_id,grant_id);
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['view_grant','invite','helper_proposal'] LOOP
  EXECUTE format('ALTER TABLE ritc.%I ENABLE ROW LEVEL SECURITY',t);
  EXECUTE format('ALTER TABLE ritc.%I FORCE ROW LEVEL SECURITY',t);
  EXECUTE format('CREATE POLICY tenant_scope ON ritc.%I USING(household_id::text=(SELECT current_setting(''app.household_id'',true))) WITH CHECK(household_id::text=(SELECT current_setting(''app.household_id'',true)))',t);
 END LOOP;
END $$;
CREATE TRIGGER view_access_lock BEFORE UPDATE OR DELETE ON ritc.view_grant FOR EACH ROW EXECUTE FUNCTION ritc.lock_household_access();
CREATE TRIGGER invite_access_lock BEFORE UPDATE OR DELETE ON ritc.invite FOR EACH ROW EXECUTE FUNCTION ritc.lock_household_access();
GRANT SELECT,INSERT ON ritc.household_creation,ritc.view_grant,ritc.invite,ritc.helper_proposal TO ritc_app;
GRANT UPDATE ON ritc.view_grant,ritc.invite TO ritc_app;
GRANT INSERT ON ritc.household,ritc.member TO ritc_app;
GRANT UPDATE(state,organizer,can_contribute,alias) ON ritc.member TO ritc_app;
GRANT UPDATE(revoked_at) ON ritc.consent,ritc.guardian_relationship TO ritc_app;

-- Never let an existing child principal acquire adult authority in another tenant.
-- Returns only a boolean; runtime cannot enumerate another tenant's members.
CREATE FUNCTION ritc.identity_has_child_profile(identity_issuer text,identity_subject text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT EXISTS(SELECT 1 FROM ritc.member WHERE issuer=identity_issuer AND subject=identity_subject AND kind='child')
$$;
REVOKE ALL ON FUNCTION ritc.identity_has_child_profile(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.identity_has_child_profile(text,text) TO ritc_app;
