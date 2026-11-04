-- Proposal only. No role, role membership, policy, source or EXECUTE grant is
-- enabled here. Provisioning a separate observer is an explicit owner action.
CREATE TABLE ritc.privacy_journal_source_registration (
 singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
 source_identity text NOT NULL CHECK(length(source_identity) BETWEEN 1 AND 200),
 database_oid oid NOT NULL,
 observer_oid oid NOT NULL
);
ALTER TABLE ritc.privacy_journal_source_registration ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.privacy_journal_source_registration FORCE ROW LEVEL SECURITY;
DO $$ BEGIN
 EXECUTE format('CREATE POLICY owner_scope ON ritc.privacy_journal_source_registration TO %I USING(true) WITH CHECK(true)',current_user);
END $$;
REVOKE ALL ON ritc.privacy_journal_source_registration FROM PUBLIC,ritc_app,ritc_worker;
CREATE TRIGGER immutable_source_registration BEFORE UPDATE OR DELETE ON ritc.privacy_journal_source_registration
 FOR EACH ROW EXECUTE FUNCTION ritc.privacy_journal_immutable();

-- The caller can neither choose an origin nor reuse this capability against a
-- restored database. session_user is the actual login, including through SET ROLE.
CREATE FUNCTION ritc.privacy_journal_source_guard(s text,l uuid,d text,c text,b oid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE registration ritc.privacy_journal_source_registration; origin ritc.privacy_journal_origin;
 actor record; owner_oid oid; actual_oid oid;
BEGIN
 SELECT * INTO STRICT registration FROM ritc.privacy_journal_source_registration WHERE singleton;
 SELECT oid INTO STRICT actual_oid FROM pg_database WHERE datname=current_database();
 SELECT oid,rolname,rolcanlogin,rolsuper,rolbypassrls,rolcreaterole,rolcreatedb,rolreplication INTO STRICT actor
  FROM pg_roles WHERE rolname=session_user;
 SELECT relowner INTO STRICT owner_oid FROM pg_class WHERE oid='ritc.privacy_journal_source_registration'::regclass;
 IF s IS DISTINCT FROM registration.source_identity OR b IS DISTINCT FROM registration.database_oid
  OR actual_oid IS DISTINCT FROM registration.database_oid OR actor.oid IS DISTINCT FROM registration.observer_oid
  OR NOT actor.rolcanlogin OR actor.rolsuper OR actor.rolbypassrls OR actor.rolcreaterole OR actor.rolcreatedb OR actor.rolreplication
  OR pg_has_role(actor.oid,owner_oid,'MEMBER') OR pg_has_role(actor.oid,'ritc_app','MEMBER')
  OR pg_has_role(actor.oid,'ritc_worker','MEMBER')
  OR COALESCE(current_setting('role',true),'none') NOT IN ('none',session_user)
 THEN RAISE EXCEPTION 'journal_source_binding_conflict' USING ERRCODE='42501'; END IF;
 SELECT * INTO STRICT origin FROM ritc.privacy_journal_origin WHERE singleton FOR SHARE;
 IF origin.lineage IS DISTINCT FROM l OR origin.schema_digest IS DISTINCT FROM d
  OR origin.configuration_id IS DISTINCT FROM c OR origin.fenced
 THEN RAISE EXCEPTION 'journal_source_origin_conflict' USING ERRCODE='42501'; END IF;
 -- Recheck effective capabilities at the function boundary. A benign inherited
 -- verifier group is acceptable only after its database-local powers are removed.
 IF EXISTS(SELECT 1 FROM pg_roles r WHERE pg_has_role(actor.oid,r.oid,'MEMBER')
   AND (r.rolsuper OR r.rolbypassrls OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication))
  OR has_database_privilege(actor.oid,actual_oid,'CREATE,TEMP')
  OR EXISTS(SELECT 1 FROM pg_database db WHERE db.oid=actual_oid AND pg_has_role(actor.oid,db.datdba,'MEMBER'))
  OR EXISTS(SELECT 1 FROM pg_namespace ns WHERE ns.nspname !~ '^pg_' AND ns.nspname<>'information_schema'
   AND (has_schema_privilege(actor.oid,ns.oid,'CREATE') OR pg_has_role(actor.oid,ns.nspowner,'MEMBER')))
  OR EXISTS(SELECT 1 FROM pg_class rel JOIN pg_namespace ns ON ns.oid=rel.relnamespace
   WHERE ns.nspname !~ '^pg_' AND ns.nspname<>'information_schema'
   AND (pg_has_role(actor.oid,rel.relowner,'MEMBER')
    OR (rel.relkind IN('r','v','m','p','f') AND has_table_privilege(actor.oid,rel.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'))
    OR (rel.relkind='S' AND has_sequence_privilege(actor.oid,rel.oid,'USAGE,SELECT,UPDATE'))))
  OR EXISTS(SELECT 1 FROM pg_attribute a JOIN pg_class rel ON rel.oid=a.attrelid JOIN pg_namespace ns ON ns.oid=rel.relnamespace
   WHERE ns.nspname !~ '^pg_' AND ns.nspname<>'information_schema' AND a.attnum>0 AND NOT a.attisdropped
   AND rel.relkind IN('r','v','m','p','f') AND has_column_privilege(actor.oid,rel.oid,a.attnum,'SELECT,INSERT,UPDATE,REFERENCES'))
  OR EXISTS(SELECT 1 FROM pg_proc f JOIN pg_namespace ns ON ns.oid=f.pronamespace WHERE ns.nspname !~ '^pg_' AND ns.nspname<>'information_schema'
   AND (pg_has_role(actor.oid,f.proowner,'MEMBER') OR (has_function_privilege(actor.oid,f.oid,'EXECUTE') AND f.oid NOT IN(
    'ritc.privacy_journal_source_binding(text,uuid,text,text,oid)'::regprocedure,
    'ritc.privacy_journal_source_event(text,uuid,text,text,oid,uuid)'::regprocedure,
    'ritc.privacy_journal_source_acceptance(text,uuid,text,text,oid,uuid)'::regprocedure,
    'ritc.privacy_journal_source_unacknowledged(text,uuid,text,text,oid,uuid,integer)'::regprocedure,
    'ritc.privacy_journal_source_acknowledge(text,uuid,text,text,oid,uuid,text,bigint,text)'::regprocedure))))
 THEN RAISE EXCEPTION 'journal_source_capability_conflict' USING ERRCODE='42501'; END IF;
 IF (SELECT count(*)<>5 OR bool_or(f.oid IS NULL OR NOT f.prosecdef OR f.proowner<>owner_oid
   OR f.proconfig IS DISTINCT FROM ARRAY['search_path=pg_catalog']::text[]
   OR NOT has_function_privilege(actor.oid,f.oid,'EXECUTE')
   OR has_function_privilege('ritc_app',f.oid,'EXECUTE') OR has_function_privilege('ritc_worker',f.oid,'EXECUTE')
   OR EXISTS(SELECT 1 FROM aclexplode(COALESCE(f.proacl,acldefault('f',f.proowner))) acl WHERE acl.grantee=0 AND acl.privilege_type='EXECUTE'))
  FROM unnest(ARRAY[
   'ritc.privacy_journal_source_binding(text,uuid,text,text,oid)'::regprocedure::oid,
   'ritc.privacy_journal_source_event(text,uuid,text,text,oid,uuid)'::regprocedure::oid,
   'ritc.privacy_journal_source_acceptance(text,uuid,text,text,oid,uuid)'::regprocedure::oid,
   'ritc.privacy_journal_source_unacknowledged(text,uuid,text,text,oid,uuid,integer)'::regprocedure::oid,
   'ritc.privacy_journal_source_acknowledge(text,uuid,text,text,oid,uuid,text,bigint,text)'::regprocedure::oid
  ]) expected(oid) LEFT JOIN pg_proc f ON f.oid=expected.oid)
 THEN RAISE EXCEPTION 'journal_source_function_conflict' USING ERRCODE='42501'; END IF;

 RETURN jsonb_build_object('sourceIdentity',registration.source_identity,'databaseName',current_database(),
  'databaseOid',actual_oid::text,'observerRole',actor.rolname,'ownerRole',pg_get_userbyid(owner_oid),
  'lineage',origin.lineage,'schemaDigest',origin.schema_digest,'configurationId',origin.configuration_id,'fenced',origin.fenced);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_journal_source_guard(text,uuid,text,text,oid) FROM PUBLIC,ritc_app,ritc_worker;

CREATE FUNCTION ritc.privacy_journal_source_binding(s text,l uuid,d text,c text,b oid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN RETURN ritc.privacy_journal_source_guard(s,l,d,c,b); END $$;
REVOKE ALL ON FUNCTION ritc.privacy_journal_source_binding(text,uuid,text,text,oid) FROM PUBLIC,ritc_app,ritc_worker;

CREATE FUNCTION ritc.privacy_journal_source_event(s text,l uuid,d text,c text,b oid,e uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE event ritc.privacy_journal_outbox;
BEGIN
 PERFORM ritc.privacy_journal_source_guard(s,l,d,c,b);
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
REVOKE ALL ON FUNCTION ritc.privacy_journal_source_event(text,uuid,text,text,oid,uuid) FROM PUBLIC,ritc_app,ritc_worker;

CREATE FUNCTION ritc.privacy_journal_source_acceptance(s text,l uuid,d text,c text,b oid,j uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE e uuid;
BEGIN
 PERFORM ritc.privacy_journal_source_guard(s,l,d,c,b);
 SELECT event_id INTO e FROM ritc.privacy_journal_outbox WHERE job_id=j AND kind='acceptance';
 IF NOT FOUND THEN RAISE EXCEPTION 'journal_source_acceptance_missing'; END IF;
 RETURN ritc.privacy_journal_source_event(s,l,d,c,b,e);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_journal_source_acceptance(text,uuid,text,text,oid,uuid) FROM PUBLIC,ritc_app,ritc_worker;

CREATE FUNCTION ritc.privacy_journal_source_unacknowledged(s text,l uuid,d text,c text,b oid,j uuid,n integer) RETURNS uuid[]
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE events uuid[];
BEGIN
 PERFORM ritc.privacy_journal_source_guard(s,l,d,c,b);
 IF n IS NULL OR n<1 OR n>10000 THEN RAISE EXCEPTION 'journal_source_list_bound'; END IF;
 PERFORM ritc.privacy_journal_source_acceptance(s,l,d,c,b,j);
 SELECT COALESCE(array_agg(event_id ORDER BY acceptance_order,created_at,event_id),'{}'::uuid[]) INTO events FROM (
  SELECT e.event_id,CASE WHEN e.kind='acceptance' THEN 0 ELSE 1 END AS acceptance_order,e.created_at
  FROM ritc.privacy_journal_outbox e WHERE e.job_id=j
   AND NOT EXISTS(SELECT 1 FROM ritc.privacy_journal_ack a WHERE a.event_id=e.event_id)
  ORDER BY acceptance_order,e.created_at,e.event_id LIMIT n+1
 ) bounded;
 IF cardinality(events)>n THEN RAISE EXCEPTION 'journal_source_list_too_large'; END IF;
 RETURN events;
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_journal_source_unacknowledged(text,uuid,text,text,oid,uuid,integer) FROM PUBLIC,ritc_app,ritc_worker;

-- External authority signatures are independently checked at the trusted Node
-- boundary immediately before this entry point. SQL rechecks its exact source
-- event and retains the original acknowledgement conflict/idempotency semantics.
CREATE FUNCTION ritc.privacy_journal_source_acknowledge(s text,l uuid,d text,c text,b oid,e uuid,p text,n bigint,h text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE event jsonb;
BEGIN
 event=ritc.privacy_journal_source_event(s,l,d,c,b,e);
 IF p IS DISTINCT FROM event->>'payloadDigest' OR n IS NULL OR n<1 OR h IS NULL OR h !~ '^[0-9a-f]{64}$'
 THEN RAISE EXCEPTION 'journal_source_ack_conflict'; END IF;
 PERFORM ritc.privacy_journal_acknowledge(e,p,n,h);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_journal_source_acknowledge(text,uuid,text,text,oid,uuid,text,bigint,text) FROM PUBLIC,ritc_app,ritc_worker;
