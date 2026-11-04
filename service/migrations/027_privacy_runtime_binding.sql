-- Read-only identity for the app and operations connection. The observer has
-- its own independent endpoint and capability checks in migration 024.
CREATE FUNCTION ritc.privacy_runtime_binding() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT jsonb_build_object('lineage',o.lineage,'schemaDigest',o.schema_digest,'configurationId',o.configuration_id,
  'sourceIdentity',s.source_identity,'database',current_database(),'databaseOid',s.database_oid::text,
  'observerRoleOid',s.observer_oid::text,'fenced',o.fenced)
 FROM ritc.privacy_journal_origin o JOIN ritc.privacy_journal_source_registration s USING(singleton)
 WHERE o.singleton AND NOT pg_is_in_recovery()
  AND s.database_oid=(SELECT oid FROM pg_database WHERE datname=current_database())
$$;
REVOKE ALL ON FUNCTION ritc.privacy_runtime_binding() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.privacy_runtime_binding() TO ritc_app,ritc_worker;
