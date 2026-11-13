-- Submit the entire file as one transaction with exactly one DO block.
SET LOCAL lock_timeout = '2s';
SET LOCAL statement_timeout = '15s';
SET LOCAL search_path = pg_catalog, pg_temp;

DO LANGUAGE plpgsql $measurement_030$
DECLARE
  target_name constant text := '030_measurement_trigger_search_path.sql';
  target_checksum constant text := '8706c4ae16b6670c43b7360bb7dcd563ac1413aee9c2c0ebce1204bdc1abb97f';
  expected_table_sha constant text := 'e74720cd49752db689ebaf47faa2113de543dc082a6000959726dfb259e083c8';
  expected_prior constant jsonb := $registry$[
  ["001_household_requests.sql", "e919302e353eae03f5cf63425ad82924c3c6315321b8b4b07e1253185e79ef5b", "2026-11-03T05:50:06.058536"],
  ["002_apple_billing.sql", "2f819c06c49f47e32c0093c636bacdfd95ad299ed159337b39041d173385ca6e", "2026-11-03T05:50:07.633945"],
  ["003_web_session.sql", "dd2b9967be0364bf313afba035e8a60fec948a94aa1cf182e9fea14e269888cb", "2026-11-03T05:50:09.051893"],
  ["004_household_lock.sql", "65fef08a239f4ea122133c335d56918e9d2ef2c4455418f36e18b6442a473250", "2026-11-03T05:50:10.624361"],
  ["005_session_and_policy_hardening.sql", "3504fec9398d40cad639aa50c931d7cbe6b585e7cf2dc5059f227b3e87727d45", "2026-11-03T06:01:26.691678"],
  ["006_household_lifecycle.sql", "7f293a0b681627cccb2d5bdc943eb3ea5c6e1436b063857f4a33f981cced296c", "2026-11-03T06:15:13.690022"],
  ["007_selected_helper_session.sql", "422f3b0cafc482adb3708689c11bbbab1d026aac69555a8dafcbd3a525f2fca5", "2026-11-03T06:15:15.110618"],
  ["008_browser_email_auth.sql", "5ad8c46d4146e1ce980e4f8809afa00512b9ed6ae6e41fd76637e0d86a713e1e", "2026-11-03T06:38:58.927914"],
  ["009_auth_maintenance.sql", "b4e33a77bc0a9576a763062e8f3dddf00c019ecbe5464ad300b1e5fa0e872b6e", "2026-11-06T06:18:22.576887"],
  ["010_account_lifecycle.sql", "e35ebbc6a2d1fcc3f7d03420542eb4ce588c3708e8bb31fcfc3ec0cc283daa22", "2026-11-06T06:18:23.099726"],
  ["011_helper_review_and_shop_selection.sql", "23457cac7c614eb8794ec0268641cd1130558ce8d8c576c4ce8bd994253d07b9", "2026-11-06T06:18:23.689402"],
  ["012_price_budget_history.sql", "dad295084f43a58cd15f58524575e98df66a77bdb0a17bd0f9555b3eac05c5c2", "2026-11-06T06:18:24.166453"],
  ["013_shared_meal_occurrences.sql", "f574ff8a6b73f0959c622053b9ebd3408d05629d653709a40d631cc58259e1d5", "2026-11-06T06:18:24.654004"],
  ["014_shared_meal_moves.sql", "2673ea349e6a7cd4df823e4128e4059533049b46071b03a1a1dc90a0d6e90a95", "2026-11-06T06:18:25.115982"],
  ["015_family_decisions.sql", "c9779d5c19bcbb2e2bc5b3f4ffe0793e459375892d9616d5c0db2ac82686def1", "2026-11-06T06:18:25.577110"],
  ["016_shared_meal_changes.sql", "362138035995832cc6b1bbffb6e9c0528ee2576945a908a14db03104355da6b0", "2026-11-06T06:18:26.042324"],
  ["017_shared_meal_ideas.sql", "fe61e6528a38cc9c6c4315587d12ee540ea624422a8e89f8933f05e75addab63", "2026-11-06T06:18:26.504814"],
  ["018_shared_store_quotes.sql", "ad18c9602e2f3c16d30f1f504ed833995bd2d09231ec405d50c7db592622b849", "2026-11-06T06:18:26.970870"],
  ["019_optional_measurement.sql", "11cf0700dd146331a6997cca80b011a04fc8028c403745dd9e6b1d8121e959a2", "2026-11-06T06:18:27.440658"],
  ["020_operations_health.sql", "daa858b576a969c5c8297a87ed88deeb4cda5c24a0b9f588f5a3429e92a0c2e7", "2026-11-06T06:18:27.921727"],
  ["021_guardian_enrollment.sql", "73e33d596776a1874aeb4715b16abed3f18829d1415ed6b0dd2799e356df4c04", "2026-11-06T06:18:28.376213"],
  ["022_privacy_journal.sql", "d64716764dd1e9b1131c7aab53faa1e67cf518875011271452ee0120d4ead5cb", "2026-11-06T06:18:28.901150"],
  ["023_device_enrollment_fence.sql", "16f737590b2d90c6ae2942b2e4983d1455f42077d477382320773b15a6629b5d", "2026-11-06T06:18:29.402478"],
  ["024_privacy_journal_source.sql", "98733f9b4a8fd8c7f7804d9be2c42a2d8a351f931a4ee820b62540c48b270185", "2026-11-06T06:18:29.868157"],
  ["025_privacy_restore_capacity.sql", "2b1788b53ee26a88d9d4e5036993e0746544c2e9b4b263449e944ff4938a2bbc", "2026-11-06T06:18:30.333059"],
  ["026_privacy_worker_capacity.sql", "5816ae80de618870134f77eefcc8cf5cdf2d667a48c8c2f25f2aa57f14a1da6c", "2026-11-06T06:18:30.793207"],
  ["027_privacy_runtime_binding.sql", "adeb438a0699c73759fc1323282efdbb416f2cef887684466dbe0b2bc02d3d0d", "2026-11-06T06:18:31.244095"],
  ["028_privacy_journal_rotation.sql", "52811aa4db7295e947c870578f1b1ba50560f43ba2dc54fc25565cb0f2f6baac", "2026-11-06T06:18:31.703613"],
  ["029_privacy_restore_window.sql", "b43b876b1da041d4cea234f6834255c7c5e7584597da2b61f67d7d0134e85ef2", "2026-11-06T06:18:32.173508"]
]$registry$::jsonb;
  expected_functions constant jsonb := $functions$[
  [
    "measurement_consent_immutable",
    "postgres",
    null,
    "\nBEGIN\n IF (NEW.household_id,NEW.consent_id,NEW.member_id,NEW.notice_version,NEW.granted_at) IS DISTINCT FROM\n    (OLD.household_id,OLD.consent_id,OLD.member_id,OLD.notice_version,OLD.granted_at)\n    OR (OLD.withdrawn_at IS NOT NULL AND NEW.withdrawn_at IS DISTINCT FROM OLD.withdrawn_at) THEN\n  RAISE EXCEPTION 'measurement consent requires a fresh explicit action' USING ERRCODE='23514';\n END IF;\n RETURN NEW;\nEND "
  ],
  [
    "measurement_feedback_eligible",
    "postgres",
    null,
    "\nBEGIN\n IF NOT EXISTS(SELECT 1 FROM ritc.measurement_consent c JOIN ritc.member m USING(household_id,member_id)\n  JOIN ritc.shop s ON s.household_id=c.household_id AND s.shop_id=NEW.shop_id AND s.shopper_id=c.member_id\n  WHERE c.household_id=NEW.household_id AND c.consent_id=NEW.consent_id AND c.member_id=NEW.member_id\n  AND c.notice_version=NEW.consent_version AND c.withdrawn_at IS NULL AND m.kind='adult' AND m.state='active'\n  AND s.phase='closed' AND s.placed_revision IS NOT NULL AND s.measurement_closed_at IS NOT NULL\n  AND NEW.eligible_week=to_char(s.measurement_closed_at AT TIME ZONE 'UTC','IYYY-\"W\"IW')) THEN\n  RAISE EXCEPTION 'current consent and eligible shared pickup required' USING ERRCODE='23514';\n END IF;\n RETURN NEW;\nEND "
  ]
]$functions$::jsonb;
  expected_config constant text[] := ARRAY['search_path=pg_catalog']::text[];
  result_config constant text[] := NULL;
  function_oids oid[];
  functions_before jsonb;
  tables_before jsonb;
  registry_before jsonb;
  registry_security_before jsonb;
  expected_registry_after jsonb;
  changed_registry_row jsonb;
BEGIN
  IF current_setting('lock_timeout') <> '2s'
     OR current_setting('statement_timeout') <> '15s'
     OR current_setting('search_path') <> 'pg_catalog, pg_temp' THEN
    RAISE EXCEPTION '030 requires transaction-local timeout and search path settings';
  END IF;
  IF current_database() <> 'postgres' OR current_user <> 'postgres'
     OR current_setting('server_version_num') <> '170011' THEN
    RAISE EXCEPTION '030 database, migration role, or PostgreSQL version drift';
  END IF;

  PERFORM pg_advisory_xact_lock(737462120::bigint);
  LOCK TABLE public.ritc_schema_migration IN SHARE ROW EXCLUSIVE MODE;

  SELECT ARRAY[
    to_regprocedure('ritc.measurement_consent_immutable()')::oid,
    to_regprocedure('ritc.measurement_feedback_eligible()')::oid
  ] INTO function_oids;
  IF array_position(function_oids, NULL) IS NOT NULL THEN
    RAISE EXCEPTION '030 target function signature missing';
  END IF;

  IF (SELECT coalesce(jsonb_agg(jsonb_build_array(version, checksum,
        to_char(applied_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US')) ORDER BY version COLLATE "C"), '[]')
      FROM public.ritc_schema_migration WHERE version <> target_name) IS DISTINCT FROM expected_prior
     OR (SELECT count(*) FROM public.ritc_schema_migration) <> 30
     OR NOT EXISTS (SELECT 1 FROM public.ritc_schema_migration
                    WHERE version = target_name AND checksum = target_checksum)
  THEN
    RAISE EXCEPTION '030 migration registry does not match the reviewed 030 baseline';
  END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(m) ORDER BY m.version COLLATE "C"), '[]') INTO registry_before
  FROM public.ritc_schema_migration m;

  IF (SELECT jsonb_agg(jsonb_build_array(p.proname, pg_get_userbyid(p.proowner), p.proacl::text, p.prosrc)
                      ORDER BY p.proname COLLATE "C")
      FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_language l ON l.oid = p.prolang
      WHERE p.oid = ANY(function_oids) AND p.prokind = 'f' AND p.pronargs = 0
        AND l.lanname = 'plpgsql' AND p.prorettype = 'pg_catalog.trigger'::regtype
        AND NOT p.prosecdef AND p.proconfig IS NOT DISTINCT FROM expected_config)
     IS DISTINCT FROM expected_functions THEN
    RAISE EXCEPTION '030 target function body, owner, ACL, invoker status or config drift';
  END IF;
  SELECT jsonb_agg(to_jsonb(p) - 'proconfig' ORDER BY p.oid) INTO functions_before
  FROM pg_catalog.pg_proc p WHERE p.oid = ANY(function_oids);

  SELECT jsonb_agg(jsonb_build_array(c.relname, pg_get_userbyid(c.relowner), c.relrowsecurity, c.relforcerowsecurity, c.relacl::text) ORDER BY c.relname COLLATE "C") INTO tables_before
  FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'ritc' AND c.relkind IN ('r', 'p');
  IF encode(sha256(convert_to(tables_before::text, 'UTF8')), 'hex') IS DISTINCT FROM expected_table_sha THEN
    RAISE EXCEPTION '030 ritc table security drift';
  END IF;
  SELECT jsonb_build_array(c.oid, c.relowner, c.relacl::text, c.relrowsecurity, c.relforcerowsecurity, c.relkind) INTO registry_security_before
  FROM pg_catalog.pg_class c WHERE c.oid = 'public.ritc_schema_migration'::regclass;

  ALTER FUNCTION ritc.measurement_consent_immutable() RESET search_path;
  ALTER FUNCTION ritc.measurement_feedback_eligible() RESET search_path;
  DELETE FROM public.ritc_schema_migration AS m WHERE m.version = target_name AND m.checksum = target_checksum
  RETURNING to_jsonb(m) INTO STRICT changed_registry_row;
  expected_registry_after := registry_before - 29;

  IF (SELECT coalesce(jsonb_agg(to_jsonb(m) ORDER BY m.version COLLATE "C"), '[]')
      FROM public.ritc_schema_migration m) IS DISTINCT FROM expected_registry_after THEN
    RAISE EXCEPTION '030 registry postcondition failed';
  END IF;
  IF (SELECT jsonb_agg(to_jsonb(p) - 'proconfig' ORDER BY p.oid)
      FROM pg_catalog.pg_proc p
      WHERE p.oid = ANY(function_oids) AND p.proconfig IS NOT DISTINCT FROM result_config)
     IS DISTINCT FROM functions_before THEN
    RAISE EXCEPTION '030 function postcondition failed';
  END IF;
  IF (SELECT jsonb_agg(jsonb_build_array(c.relname, pg_get_userbyid(c.relowner), c.relrowsecurity, c.relforcerowsecurity, c.relacl::text) ORDER BY c.relname COLLATE "C")
      FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'ritc' AND c.relkind IN ('r', 'p')) IS DISTINCT FROM tables_before
     OR (SELECT jsonb_build_array(c.oid, c.relowner, c.relacl::text, c.relrowsecurity, c.relforcerowsecurity, c.relkind)
         FROM pg_catalog.pg_class c WHERE c.oid = 'public.ritc_schema_migration'::regclass)
     IS DISTINCT FROM registry_security_before THEN
    RAISE EXCEPTION '030 table security postcondition failed';
  END IF;
END
$measurement_030$;
