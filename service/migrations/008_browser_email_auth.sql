-- Server-owned email authentication state. No provider token is sent to browser JS.
CREATE TABLE ritc.browser_auth (
 token_hash text PRIMARY KEY CHECK(length(token_hash)=64), csrf text NOT NULL,
 phase text NOT NULL DEFAULT 'challenge' CHECK(phase IN ('challenge','authenticated')),
 issuer text, subject text, session_id text, access_expires_at timestamptz,
 secret_cipher text, email_cipher text, code_expires_at timestamptz, send_after timestamptz,
 verify_attempts integer NOT NULL DEFAULT 0 CHECK(verify_attempts BETWEEN 0 AND 5),
 expires_at timestamptz NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), revoked_at timestamptz,
 CHECK(phase<>'authenticated' OR (issuer IS NOT NULL AND subject IS NOT NULL AND session_id IS NOT NULL AND access_expires_at IS NOT NULL AND secret_cipher IS NOT NULL))
);
ALTER TABLE ritc.browser_auth ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.browser_auth FORCE ROW LEVEL SECURITY;
CREATE POLICY browser_cookie_scope ON ritc.browser_auth USING(token_hash=(SELECT current_setting('app.browser_token_hash',true))) WITH CHECK(token_hash=(SELECT current_setting('app.browser_token_hash',true)));
CREATE INDEX browser_auth_expiry ON ritc.browser_auth(expires_at);
CREATE TABLE ritc.auth_rate_bucket (
 bucket_key text PRIMARY KEY CHECK(length(bucket_key)=64), window_started timestamptz NOT NULL, attempts integer NOT NULL CHECK(attempts>0)
);
ALTER TABLE ritc.auth_rate_bucket ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.auth_rate_bucket FORCE ROW LEVEL SECURITY;
CREATE POLICY auth_rate_scope ON ritc.auth_rate_bucket USING(bucket_key=(SELECT current_setting('app.auth_rate_key',true))) WITH CHECK(bucket_key=(SELECT current_setting('app.auth_rate_key',true)));
GRANT SELECT,INSERT,UPDATE ON ritc.browser_auth,ritc.auth_rate_bucket TO ritc_app;

-- A BFF-enrolled scope cannot outlive or bypass its authenticated browser context.
ALTER TABLE ritc.web_session ADD COLUMN browser_bound boolean NOT NULL DEFAULT false;
