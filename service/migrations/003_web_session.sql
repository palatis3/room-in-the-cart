CREATE TABLE ritc.web_session (
  household_id uuid NOT NULL, token_hash text NOT NULL CHECK(length(token_hash)=64),
  member_id uuid NOT NULL, device_id uuid NOT NULL, csrf text NOT NULL,
  expires_at timestamptz NOT NULL, revoked_at timestamptz,
  PRIMARY KEY(household_id,token_hash),
  FOREIGN KEY(household_id,member_id,device_id) REFERENCES ritc.device(household_id,member_id,device_id)
);
ALTER TABLE ritc.web_session ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.web_session FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON ritc.web_session USING(household_id::text=current_setting('app.household_id',true)) WITH CHECK(household_id::text=current_setting('app.household_id',true));
GRANT SELECT,INSERT,UPDATE ON ritc.web_session TO ritc_app;
