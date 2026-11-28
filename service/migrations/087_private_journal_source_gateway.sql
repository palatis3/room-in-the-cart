-- Five fixed operations for the isolated source gateway. This migration creates
-- no login, membership, source registration or grant to a deployment principal.
CREATE SCHEMA ritc_journal_source;
REVOKE ALL ON SCHEMA ritc_journal_source FROM PUBLIC;

CREATE FUNCTION ritc_journal_source.guard(s text,l uuid,d text,c text,b oid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE
 registration ritc.privacy_journal_source_registration;
 origin ritc.privacy_journal_origin;
 actor pg_catalog.pg_roles;
 db pg_catalog.pg_database;
 owner_oid oid;
 gateway_oid oid := 'ritc_journal_source'::regnamespace;
 permitted oid[] := ARRAY[
  'ritc_journal_source.privacy_journal_source_binding(text,uuid,text,text,oid)'::regprocedure,
  'ritc_journal_source.privacy_journal_source_event(text,uuid,text,text,oid,uuid)'::regprocedure,
  'ritc_journal_source.privacy_journal_source_acceptance(text,uuid,text,text,oid,uuid)'::regprocedure,
  'ritc_journal_source.privacy_journal_source_unacknowledged(text,uuid,text,text,oid,uuid,integer)'::regprocedure,
  'ritc_journal_source.privacy_journal_source_acknowledge(text,uuid,text,text,oid,uuid,text,bigint,text)'::regprocedure
 ];
BEGIN
 SELECT * INTO STRICT registration FROM ritc.privacy_journal_source_registration WHERE singleton;
 SELECT * INTO STRICT db FROM pg_catalog.pg_database WHERE datname=current_database();
 SELECT * INTO STRICT actor FROM pg_catalog.pg_roles WHERE rolname=session_user;
 SELECT relowner INTO STRICT owner_oid FROM pg_catalog.pg_class WHERE oid='ritc.privacy_journal_source_registration'::regclass;
 IF s IS DISTINCT FROM registration.source_identity OR b IS DISTINCT FROM registration.database_oid
  OR db.oid<>registration.database_oid OR actor.oid<>registration.observer_oid
  OR actor.oid IN (owner_oid,db.datdba) OR NOT actor.rolcanlogin OR actor.rolsuper OR actor.rolbypassrls
  OR actor.rolcreaterole OR actor.rolcreatedb OR actor.rolreplication OR actor.rolname IN ('ritc_app','ritc_worker')
  OR EXISTS(SELECT FROM pg_catalog.pg_auth_members WHERE member=actor.oid)
  OR COALESCE(current_setting('role',true),'none')<>'none' OR pg_my_temp_schema()<>0
 THEN RAISE EXCEPTION 'journal_gateway_identity_conflict' USING ERRCODE='42501'; END IF;
 SELECT * INTO STRICT origin FROM ritc.privacy_journal_origin WHERE singleton FOR SHARE;
 IF origin.lineage IS DISTINCT FROM l OR origin.schema_digest IS DISTINCT FROM d
  OR origin.configuration_id IS DISTINCT FROM c OR origin.fenced
 THEN RAISE EXCEPTION 'journal_gateway_origin_conflict' USING ERRCODE='42501'; END IF;

 -- Only the trusted connector has a SQL login. Its callers get fixed HTTPS
 -- operations. No grant to another role or change to a provider ACL is needed.
 IF has_database_privilege(actor.oid,db.oid,'CREATE') OR NOT has_database_privilege(actor.oid,db.oid,'CONNECT')
  OR EXISTS(SELECT FROM aclexplode(db.datacl) a WHERE a.grantee=actor.oid AND (a.privilege_type<>'CONNECT' OR a.is_grantable))
  OR NOT has_schema_privilege(actor.oid,gateway_oid,'USAGE')
  OR EXISTS(SELECT FROM pg_catalog.pg_namespace ns WHERE ns.nspname !~ '^pg_' AND ns.nspname<>'information_schema'
    AND (ns.nspowner=actor.oid OR has_schema_privilege(actor.oid,ns.oid,'CREATE')
     OR (ns.oid<>gateway_oid AND ns.nspname<>'public' AND has_schema_privilege(actor.oid,ns.oid,'USAGE'))))
  OR EXISTS(SELECT FROM pg_catalog.pg_foreign_server srv WHERE srv.srvowner=actor.oid OR has_server_privilege(actor.oid,srv.oid,'USAGE'))
  OR EXISTS(SELECT FROM pg_catalog.pg_foreign_data_wrapper fdw WHERE fdw.fdwowner=actor.oid OR has_foreign_data_wrapper_privilege(actor.oid,fdw.oid,'USAGE'))
  OR EXISTS(SELECT FROM pg_catalog.pg_class r JOIN pg_catalog.pg_namespace ns ON ns.oid=r.relnamespace
    WHERE ns.nspname !~ '^pg_' AND ns.nspname<>'information_schema' AND (r.relowner=actor.oid
     OR EXISTS(SELECT FROM aclexplode(r.relacl) a WHERE a.grantee=actor.oid
       OR (a.grantee=0 AND has_schema_privilege(actor.oid,ns.oid,'USAGE')))))
  OR EXISTS(SELECT FROM pg_catalog.pg_attribute col JOIN pg_catalog.pg_class r ON r.oid=col.attrelid
    JOIN pg_catalog.pg_namespace ns ON ns.oid=r.relnamespace WHERE ns.nspname !~ '^pg_' AND ns.nspname<>'information_schema'
    AND col.attnum>0 AND NOT col.attisdropped AND EXISTS(SELECT FROM aclexplode(col.attacl) a WHERE a.grantee=actor.oid
     OR (a.grantee=0 AND has_schema_privilege(actor.oid,ns.oid,'USAGE'))))
  OR EXISTS(SELECT FROM pg_catalog.pg_proc f JOIN pg_catalog.pg_namespace ns ON ns.oid=f.pronamespace
    WHERE ns.nspname !~ '^pg_' AND ns.nspname<>'information_schema' AND (f.proowner=actor.oid OR
     (f.oid<>ALL(permitted) AND EXISTS(SELECT FROM aclexplode(COALESCE(f.proacl,acldefault('f',f.proowner))) a
      WHERE a.grantee=actor.oid OR (a.grantee=0 AND has_schema_privilege(actor.oid,ns.oid,'USAGE'))))))
 THEN RAISE EXCEPTION 'journal_gateway_capability_conflict' USING ERRCODE='42501'; END IF;

 IF (SELECT nspowner<>owner_oid OR EXISTS(SELECT FROM aclexplode(nspacl) a WHERE
     a.grantee NOT IN(owner_oid,actor.oid) OR (a.grantee=actor.oid AND (a.privilege_type<>'USAGE' OR a.is_grantable)))
    FROM pg_catalog.pg_namespace WHERE oid=gateway_oid)
  OR EXISTS(SELECT FROM unnest(permitted) e(oid) LEFT JOIN pg_catalog.pg_proc f ON f.oid=e.oid
    WHERE f.oid IS NULL OR f.pronamespace<>gateway_oid OR NOT f.prosecdef OR f.proowner<>owner_oid
     OR f.proconfig IS DISTINCT FROM ARRAY['search_path=pg_catalog, pg_temp']::text[]
     OR NOT has_function_privilege(actor.oid,f.oid,'EXECUTE') OR EXISTS(
      SELECT FROM aclexplode(COALESCE(f.proacl,acldefault('f',f.proowner))) a
       WHERE a.grantee NOT IN(owner_oid,actor.oid) OR (a.grantee=actor.oid AND a.is_grantable)))
 THEN RAISE EXCEPTION 'journal_gateway_interface_conflict' USING ERRCODE='42501'; END IF;
 RETURN jsonb_build_object('sourceIdentity',registration.source_identity,'databaseName',current_database(),
  'databaseOid',db.oid::text,'observerRole',actor.rolname,'ownerRole',pg_get_userbyid(owner_oid),
  'lineage',origin.lineage,'schemaDigest',origin.schema_digest,'configurationId',origin.configuration_id,'fenced',origin.fenced);
END $$;

CREATE FUNCTION ritc_journal_source.privacy_journal_source_binding(s text,l uuid,d text,c text,b oid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN RETURN ritc_journal_source.guard(s,l,d,c,b); END $$;

CREATE FUNCTION ritc_journal_source.privacy_journal_source_event(s text,l uuid,d text,c text,b oid,e uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE event ritc.privacy_journal_outbox;
BEGIN
 PERFORM ritc_journal_source.guard(s,l,d,c,b);
 SELECT * INTO event FROM ritc.privacy_journal_outbox WHERE event_id=e;
 IF NOT FOUND THEN RAISE EXCEPTION 'journal_source_event_missing'; END IF;
 IF octet_length(event.payload::text)>1048576 THEN RAISE EXCEPTION 'journal_source_event_too_large'; END IF;
 IF event.lineage IS DISTINCT FROM l OR event.payload->>'lineage' IS DISTINCT FROM l::text
  OR event.payload->>'schemaDigest' IS DISTINCT FROM d OR event.payload->>'configurationId' IS DISTINCT FROM c
  OR event.payload->>'eventId' IS DISTINCT FROM event.event_id::text OR event.payload->>'jobId' IS DISTINCT FROM event.job_id::text
  OR event.payload->>'kind' IS DISTINCT FROM event.kind
  OR event.payload_digest IS DISTINCT FROM encode(sha256(convert_to(ritc.privacy_journal_canonical(event.payload),'utf8')),'hex')
 THEN RAISE EXCEPTION 'journal_source_event_conflict'; END IF;
 RETURN jsonb_build_object('eventId',event.event_id,'payloadDigest',event.payload_digest,'payload',event.payload);
END $$;

CREATE FUNCTION ritc_journal_source.privacy_journal_source_acceptance(s text,l uuid,d text,c text,b oid,j uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE e uuid;
BEGIN
 PERFORM ritc_journal_source.guard(s,l,d,c,b);
 SELECT event_id INTO e FROM ritc.privacy_journal_outbox WHERE job_id=j AND kind='acceptance';
 IF NOT FOUND THEN RAISE EXCEPTION 'journal_source_acceptance_missing'; END IF;
 RETURN ritc_journal_source.privacy_journal_source_event(s,l,d,c,b,e);
END $$;

CREATE FUNCTION ritc_journal_source.privacy_journal_source_unacknowledged(s text,l uuid,d text,c text,b oid,j uuid,n integer) RETURNS uuid[]
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE events uuid[];
BEGIN
 PERFORM ritc_journal_source.guard(s,l,d,c,b);
 IF n IS NULL OR n<1 OR n>10000 THEN RAISE EXCEPTION 'journal_source_list_bound'; END IF;
 PERFORM ritc_journal_source.privacy_journal_source_acceptance(s,l,d,c,b,j);
 SELECT COALESCE(array_agg(event_id ORDER BY acceptance_order,created_at,event_id),'{}'::uuid[]) INTO events FROM (
  SELECT e.event_id,CASE WHEN e.kind='acceptance' THEN 0 ELSE 1 END AS acceptance_order,e.created_at
  FROM ritc.privacy_journal_outbox e WHERE e.job_id=j
   AND NOT EXISTS(SELECT 1 FROM ritc.privacy_journal_ack a WHERE a.event_id=e.event_id)
  ORDER BY acceptance_order,e.created_at,e.event_id LIMIT n+1
 ) bounded;
 IF cardinality(events)>n THEN RAISE EXCEPTION 'journal_source_list_too_large'; END IF;
 RETURN events;
END $$;

-- External authority signatures are independently checked at the trusted Node
-- boundary immediately before this entry point. SQL rechecks its exact source
-- event and retains the original acknowledgement conflict/idempotency semantics.
CREATE FUNCTION ritc_journal_source.privacy_journal_source_acknowledge(s text,l uuid,d text,c text,b oid,e uuid,p text,n bigint,h text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE event jsonb;
BEGIN
 event=ritc_journal_source.privacy_journal_source_event(s,l,d,c,b,e);
 IF p IS DISTINCT FROM event->>'payloadDigest' OR n IS NULL OR n<1 OR h IS NULL OR h !~ '^[0-9a-f]{64}$'
 THEN RAISE EXCEPTION 'journal_source_ack_conflict'; END IF;
 PERFORM ritc.privacy_journal_acknowledge(e,p,n,h);
END $$;


-- Owner default ACLs vary by installation. Reset only this newly-created
-- namespace and its newly-created functions before the transaction commits.
DO $$
DECLARE grantee_name text;
BEGIN
 REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ritc_journal_source FROM PUBLIC;
 FOR grantee_name IN
  SELECT DISTINCT pg_get_userbyid(a.grantee) FROM pg_catalog.pg_proc f,
   LATERAL aclexplode(f.proacl) a WHERE f.pronamespace='ritc_journal_source'::regnamespace
    AND a.grantee NOT IN (0,f.proowner)
 LOOP EXECUTE format('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ritc_journal_source FROM %I',grantee_name); END LOOP;
 FOR grantee_name IN SELECT pg_get_userbyid(a.grantee) FROM pg_catalog.pg_namespace ns,
  LATERAL aclexplode(ns.nspacl) a WHERE ns.oid='ritc_journal_source'::regnamespace AND a.grantee NOT IN (0,ns.nspowner)
 LOOP EXECUTE format('REVOKE ALL ON SCHEMA ritc_journal_source FROM %I',grantee_name); END LOOP;
END $$;
