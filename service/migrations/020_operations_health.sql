-- Aggregate operations evidence is visible only to the separate worker login.
-- No subject, session, token, payload, free text, or household identifier leaves
-- this SECURITY DEFINER boundary. Counts are bounded by a statement timeout.
CREATE FUNCTION ritc.operations_health() RETURNS TABLE(
 auth_due bigint, auth_retry_pending bigint, auth_expired_unconfirmed bigint,
 privacy_pending bigint, privacy_due bigint
)
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT
  (SELECT count(*) FROM ritc.browser_auth a WHERE a.secret_cipher IS NOT NULL
    AND (a.revoked_at IS NOT NULL OR a.expires_at<=clock_timestamp())
    AND a.logout_state NOT IN ('complete','expired_unconfirmed')
    AND (a.logout_next_at IS NULL OR a.logout_next_at<=clock_timestamp())
    AND (a.logout_lease_until IS NULL OR a.logout_lease_until<clock_timestamp())),
  (SELECT count(*) FROM ritc.browser_auth a WHERE a.logout_state IN ('pending','leased')),
  (SELECT count(*) FROM ritc.browser_auth a WHERE a.logout_state='expired_unconfirmed'),
  (SELECT count(*) FROM ritc.privacy_job j WHERE j.state<>'complete'),
  (SELECT count(*) FROM ritc.privacy_job j WHERE j.state<>'complete' AND j.next_at<=clock_timestamp()
    AND (j.lease_until IS NULL OR j.lease_until<clock_timestamp()))
$$;
REVOKE ALL ON FUNCTION ritc.operations_health() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.operations_health() TO ritc_worker;
