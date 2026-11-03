-- Additive hardening only; applied migrations 001-004 are immutable.
ALTER FUNCTION ritc.immutable_row() SET search_path=pg_catalog;
ALTER FUNCTION ritc.lock_household_access() SET search_path=pg_catalog;
ALTER FUNCTION ritc.consent_revoke_once() SET search_path=pg_catalog;
ALTER FUNCTION ritc.billing_adult_seat() SET search_path=pg_catalog;
-- Private boolean authority, never exposed through PostgREST. Runtime cannot read auth rows.
CREATE FUNCTION ritc.provider_session_live(session_id uuid, subject_id uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  -- SHARE prevents provider deletion until this authorized transaction completes.
  PERFORM 1 FROM auth.sessions s WHERE s.id=session_id AND s.user_id=subject_id
    AND (s.not_after IS NULL OR s.not_after>clock_timestamp()) FOR SHARE;
  RETURN FOUND;
END $$;
REVOKE ALL ON FUNCTION ritc.provider_session_live(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.provider_session_live(uuid,uuid) TO ritc_app;
-- Preserve every tenant policy's null/unset semantics; cache stable request settings.
DO $$ DECLARE p record; BEGIN
  FOR p IN SELECT tablename FROM pg_policies WHERE schemaname='ritc' AND policyname='tenant_scope' LOOP
    EXECUTE format('ALTER POLICY tenant_scope ON ritc.%I USING(household_id::text=(SELECT current_setting(''app.household_id'',true))) WITH CHECK(household_id::text=(SELECT current_setting(''app.household_id'',true)))',p.tablename);
  END LOOP;
END $$;
ALTER POLICY own_membership_lookup ON ritc.member USING(issuer=(SELECT current_setting('app.issuer',true)) AND subject=(SELECT current_setting('app.subject',true)) AND state='active');
ALTER POLICY own_household_lookup ON ritc.household USING(EXISTS(SELECT 1 FROM ritc.member m WHERE m.household_id=household.household_id AND m.issuer=(SELECT current_setting('app.issuer',true)) AND m.subject=(SELECT current_setting('app.subject',true)) AND m.state='active'));
ALTER POLICY verified_apple_notification_route ON ritc.billing_account USING(app_account_token::text=(SELECT current_setting('app.billing_token',true)));
-- Cover referencing columns to keep tenant revocation and cleanup bounded.
DO $$ DECLARE fk record; BEGIN
  FOR fk IN SELECT c.conrelid,c.conkey,c.conname,n.nspname,t.relname FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid JOIN pg_namespace n ON n.oid=t.relnamespace
    WHERE c.contype='f' AND n.nspname='ritc' AND NOT EXISTS(SELECT 1 FROM pg_index i WHERE i.indrelid=c.conrelid AND i.indisvalid AND i.indpred IS NULL AND (i.indkey::smallint[])[0:array_length(c.conkey,1)-1]=c.conkey) LOOP
    EXECUTE format('CREATE INDEX %I ON %I.%I (%s)','fk_'||substr(md5(fk.relname||fk.conname),1,24),fk.nspname,fk.relname,(SELECT string_agg(quote_ident(a.attname),',' ORDER BY k.ordinality) FROM unnest(fk.conkey) WITH ORDINALITY k(attnum,ordinality) JOIN pg_attribute a ON a.attrelid=fk.conrelid AND a.attnum=k.attnum));
  END LOOP;
END $$;
-- Inspect matching known platform source before removing public direct-call permission.
DO $$ DECLARE f record; r text; BEGIN
  SELECT p.oid,p.prosecdef,p.prorettype,p.prosrc INTO f FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='rls_auto_enable' AND p.pronargs=0;
  IF FOUND THEN
    IF NOT f.prosecdef OR f.prorettype<>'event_trigger'::regtype OR md5(f.prosrc)<>'c44fb229ea8a6b0afd04a0a33261c16c' THEN RAISE EXCEPTION 'Review changed platform rls_auto_enable definition before revoking'; END IF;
    REVOKE EXECUTE ON FUNCTION public.rls_auto_enable() FROM PUBLIC;
    FOREACH r IN ARRAY ARRAY['anon','authenticated'] LOOP
      IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname=r) THEN EXECUTE format('REVOKE EXECUTE ON FUNCTION public.rls_auto_enable() FROM %I',r); END IF;
    END LOOP;
  END IF;
END $$;
