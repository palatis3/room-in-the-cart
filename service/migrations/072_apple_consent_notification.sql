-- App Store download consent events have no household or guardian identity.
CREATE TABLE ritc.apple_consent_notification (
  environment text NOT NULL CHECK (environment IN ('Production', 'Sandbox')),
  notification_id uuid NOT NULL,
  signed_at timestamptz NOT NULL,
  PRIMARY KEY (environment, notification_id)
);
REVOKE ALL ON ritc.apple_consent_notification FROM PUBLIC, ritc_app;
GRANT INSERT (environment, notification_id, signed_at) ON ritc.apple_consent_notification TO ritc_app;
ALTER TABLE ritc.apple_consent_notification ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.apple_consent_notification FORCE ROW LEVEL SECURITY;
CREATE POLICY verified_consent_receipt ON ritc.apple_consent_notification
  FOR INSERT TO ritc_app WITH CHECK (true);
