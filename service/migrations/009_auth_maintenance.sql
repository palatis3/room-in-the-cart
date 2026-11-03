-- Operational role is distinct from the application role and cannot read auth payloads directly.
DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='ritc_worker') THEN CREATE ROLE ritc_worker NOLOGIN NOSUPERUSER NOBYPASSRLS; END IF; END $$;
GRANT USAGE ON SCHEMA ritc TO ritc_worker;
ALTER TABLE ritc.browser_auth ADD COLUMN logout_state text NOT NULL DEFAULT 'none' CHECK(logout_state IN ('none','pending','leased','complete','expired_unconfirmed'));
ALTER TABLE ritc.browser_auth ADD COLUMN logout_attempts integer NOT NULL DEFAULT 0 CHECK(logout_attempts>=0);
ALTER TABLE ritc.browser_auth ADD COLUMN logout_next_at timestamptz;
ALTER TABLE ritc.browser_auth ADD COLUMN logout_lease_id uuid;
ALTER TABLE ritc.browser_auth ADD COLUMN logout_lease_until timestamptz;
ALTER TABLE ritc.browser_auth ADD COLUMN logout_finished_at timestamptz;
ALTER TABLE ritc.browser_auth ADD COLUMN logout_last_error text CHECK(logout_last_error IN ('provider_unavailable','configuration_unavailable','token_expired','cipher_unavailable'));
CREATE INDEX browser_auth_logout_due ON ritc.browser_auth(logout_next_at,expires_at) WHERE secret_cipher IS NOT NULL;

CREATE FUNCTION ritc.maintenance_prepare_auth(batch_size integer) RETURNS TABLE(expired_queued integer,emails_cleared integer,auth_purged integer,rates_purged integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE n integer:=greatest(1,least(batch_size,100));
BEGIN
 WITH candidates AS (SELECT a.token_hash FROM ritc.browser_auth a WHERE a.phase='authenticated' AND a.expires_at<=clock_timestamp() AND a.revoked_at IS NULL ORDER BY a.expires_at,a.token_hash FOR UPDATE SKIP LOCKED LIMIT n)
 UPDATE ritc.browser_auth a SET revoked_at=clock_timestamp(),email_cipher=NULL,logout_state='pending',logout_next_at=clock_timestamp() FROM candidates c WHERE a.token_hash=c.token_hash;
 GET DIAGNOSTICS expired_queued=ROW_COUNT;
 WITH candidates AS (SELECT a.token_hash FROM ritc.browser_auth a WHERE a.email_cipher IS NOT NULL AND (a.code_expires_at<=clock_timestamp() OR a.revoked_at IS NOT NULL) ORDER BY a.expires_at,a.token_hash FOR UPDATE SKIP LOCKED LIMIT n)
 UPDATE ritc.browser_auth a SET email_cipher=NULL,code_expires_at=NULL FROM candidates c WHERE a.token_hash=c.token_hash;
 GET DIAGNOSTICS emails_cleared=ROW_COUNT;
 WITH candidates AS (SELECT a.token_hash FROM ritc.browser_auth a WHERE a.secret_cipher IS NULL AND (a.expires_at<=clock_timestamp() OR a.revoked_at IS NOT NULL) ORDER BY a.expires_at,a.token_hash FOR UPDATE SKIP LOCKED LIMIT n)
 DELETE FROM ritc.browser_auth a USING candidates c WHERE a.token_hash=c.token_hash;
 GET DIAGNOSTICS auth_purged=ROW_COUNT;
 WITH candidates AS (SELECT r.bucket_key FROM ritc.auth_rate_bucket r WHERE r.window_started<clock_timestamp()-interval '24 hours' ORDER BY r.window_started,r.bucket_key FOR UPDATE SKIP LOCKED LIMIT n)
 DELETE FROM ritc.auth_rate_bucket r USING candidates c WHERE r.bucket_key=c.bucket_key;
 GET DIAGNOSTICS rates_purged=ROW_COUNT;
 RETURN NEXT;
END $$;
CREATE FUNCTION ritc.maintenance_claim_logout(lease_id uuid) RETURNS TABLE(token_hash text,secret_cipher text,subject text,session_id text,access_expires_at timestamptz,attempt integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 RETURN QUERY WITH candidate AS (
  SELECT a.token_hash FROM ritc.browser_auth a WHERE a.secret_cipher IS NOT NULL AND (a.revoked_at IS NOT NULL OR a.expires_at<=clock_timestamp())
    AND a.logout_state NOT IN ('complete','expired_unconfirmed') AND (a.logout_next_at IS NULL OR a.logout_next_at<=clock_timestamp())
    AND (a.logout_lease_until IS NULL OR a.logout_lease_until<clock_timestamp())
  ORDER BY a.logout_next_at NULLS FIRST,a.expires_at,a.token_hash FOR UPDATE SKIP LOCKED LIMIT 1
 ) UPDATE ritc.browser_auth a SET revoked_at=COALESCE(a.revoked_at,clock_timestamp()),email_cipher=NULL,logout_state='leased',logout_lease_id=lease_id,
 logout_lease_until=clock_timestamp()+interval '30 seconds',logout_attempts=a.logout_attempts+1
 FROM candidate c WHERE a.token_hash=c.token_hash
 RETURNING a.token_hash,a.secret_cipher,a.subject,a.session_id,a.access_expires_at,a.logout_attempts;
END $$;
CREATE FUNCTION ritc.maintenance_finish_logout(record_hash text,lease_id uuid,outcome text,error_code text DEFAULT NULL) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF outcome NOT IN ('complete','retry','expired_unconfirmed') OR (error_code IS NOT NULL AND error_code NOT IN ('provider_unavailable','configuration_unavailable','token_expired','cipher_unavailable')) THEN RAISE EXCEPTION 'invalid maintenance outcome'; END IF;
 IF outcome='retry' THEN
  UPDATE ritc.browser_auth a SET logout_state='pending',logout_next_at=clock_timestamp()+make_interval(secs=>least(3600,30*power(2,least(a.logout_attempts,7)))::integer),
   logout_lease_id=NULL,logout_lease_until=NULL,logout_last_error=error_code WHERE a.token_hash=record_hash AND a.logout_lease_id=lease_id AND a.logout_state='leased';
 ELSE
  UPDATE ritc.browser_auth a SET logout_state=outcome,logout_finished_at=clock_timestamp(),logout_last_error=error_code,logout_lease_id=NULL,logout_lease_until=NULL,
   phase='challenge',secret_cipher=NULL,email_cipher=NULL,issuer=NULL,subject=NULL,session_id=NULL,access_expires_at=NULL
  WHERE a.token_hash=record_hash AND a.logout_lease_id=lease_id AND a.logout_state='leased';
 END IF;
 RETURN FOUND;
END $$;
CREATE FUNCTION ritc.maintenance_provider_session_present(provider_session uuid,provider_subject uuid) RETURNS boolean
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog AS $$ SELECT EXISTS(SELECT 1 FROM auth.sessions s WHERE s.id=provider_session AND s.user_id=provider_subject) $$;
REVOKE ALL ON FUNCTION ritc.maintenance_prepare_auth(integer),ritc.maintenance_claim_logout(uuid),ritc.maintenance_finish_logout(text,uuid,text,text),ritc.maintenance_provider_session_present(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.maintenance_prepare_auth(integer),ritc.maintenance_claim_logout(uuid),ritc.maintenance_finish_logout(text,uuid,text,text),ritc.maintenance_provider_session_present(uuid,uuid) TO ritc_worker;
-- A refresh may itself update auth.sessions. Do not hold the request authorization SHARE lock
-- across the provider call; recheck and lock the returned binding after verification.
CREATE FUNCTION ritc.provider_session_refreshable(provider_session uuid,provider_subject uuid) RETURNS boolean
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT EXISTS(SELECT 1 FROM auth.sessions s WHERE s.id=provider_session AND s.user_id=provider_subject AND (s.not_after IS NULL OR s.not_after>clock_timestamp()))
$$;
REVOKE ALL ON FUNCTION ritc.provider_session_refreshable(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.provider_session_refreshable(uuid,uuid) TO ritc_app;
