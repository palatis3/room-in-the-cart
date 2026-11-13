-- Adapted from the local Supabase migration-new skeleton to the existing checksum
-- runner. Private schema; no hosted action, Data API grants or legacy backfill.
ALTER TABLE ritc.shop ADD COLUMN tracking_privacy_revision integer NOT NULL DEFAULT 0 CHECK(tracking_privacy_revision>=0);
CREATE TABLE ritc.shared_tracking_revision(
 household_id uuid NOT NULL,shop_id uuid NOT NULL,shop_revision integer NOT NULL CHECK(shop_revision>0),
 graph_revision integer NOT NULL CHECK(graph_revision>0),authority_epoch integer NOT NULL CHECK(authority_epoch>0),privacy_revision integer NOT NULL CHECK(privacy_revision>=0),
 operation_id uuid NOT NULL,actor_id uuid NOT NULL,device_id uuid NOT NULL,
 state jsonb,state_digest text,projection jsonb,review jsonb,reverses_operation_id uuid,
 PRIMARY KEY(household_id,shop_id,shop_revision),UNIQUE(household_id,operation_id),UNIQUE(household_id,reverses_operation_id),
 CHECK((state IS NOT NULL AND state_digest IS NOT NULL AND projection IS NULL) OR (state IS NULL AND state_digest IS NULL AND projection IS NOT NULL AND review IS NULL)),
 CHECK(state_digest IS NULL OR state_digest ~ '^[0-9a-f]{64}$'),
 CHECK(state IS NULL OR (state->>'schemaVersion' IS NOT NULL AND state->>'schemaVersion'='2'
  AND state#>>'{graph,householdId}' IS NOT NULL AND (state#>>'{graph,householdId}')::uuid=household_id
  AND state#>>'{graph,shopId}' IS NOT NULL AND (state#>>'{graph,shopId}')::uuid=shop_id
  AND state#>>'{graph,revision}' IS NOT NULL AND (state#>>'{graph,revision}')::integer=graph_revision
  AND state->>'privacyRevision' IS NOT NULL AND (state->>'privacyRevision')::integer=privacy_revision)),
 CHECK(projection IS NULL OR (projection->>'status' IS NOT NULL AND projection->>'status'='reviewRequired'
  AND projection#>>'{state,graph,householdId}' IS NOT NULL AND (projection#>>'{state,graph,householdId}')::uuid=household_id
  AND projection#>>'{state,graph,shopId}' IS NOT NULL AND (projection#>>'{state,graph,shopId}')::uuid=shop_id)),
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,
 FOREIGN KEY(household_id,shop_id,shop_revision) REFERENCES ritc.shop_snapshot(household_id,shop_id,revision) DEFERRABLE INITIALLY DEFERRED,
 FOREIGN KEY(household_id,shop_id,graph_revision) REFERENCES ritc.shared_demand_revision DEFERRABLE INITIALLY DEFERRED,
 FOREIGN KEY(household_id,operation_id) REFERENCES ritc.operation DEFERRABLE INITIALLY DEFERRED,
 FOREIGN KEY(household_id,reverses_operation_id) REFERENCES ritc.operation,
 FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member,FOREIGN KEY(household_id,device_id) REFERENCES ritc.device
);
CREATE TABLE ritc.shared_tracking_adoption(
 household_id uuid NOT NULL,shop_id uuid NOT NULL,operation_id uuid NOT NULL,authority_epoch integer NOT NULL,
 evidence jsonb,evidence_digest text,store_basis jsonb,
 PRIMARY KEY(household_id,operation_id),
 CHECK((evidence IS NULL)=(evidence_digest IS NULL)),CHECK(evidence_digest IS NULL OR evidence_digest ~ '^[0-9a-f]{64}$'),
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,
 FOREIGN KEY(household_id,operation_id) REFERENCES ritc.operation DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE ritc.shared_tracking_preview(
 household_id uuid NOT NULL,shop_id uuid NOT NULL,preview_id uuid NOT NULL,operation_id uuid NOT NULL,
 actor_id uuid NOT NULL,device_id uuid NOT NULL,authority_epoch integer NOT NULL,shop_revision integer NOT NULL,
 intent jsonb NOT NULL,candidate_digest text NOT NULL,accepted_digest text,review jsonb,
 created_at timestamptz NOT NULL,expires_at timestamptz NOT NULL,
 PRIMARY KEY(household_id,preview_id),UNIQUE(household_id,operation_id),
 CHECK(expires_at>created_at AND expires_at<=created_at+interval '10 minutes'),
 CHECK(candidate_digest ~ '^[0-9a-f]{64}$'),CHECK(accepted_digest IS NULL OR accepted_digest ~ '^[0-9a-f]{64}$'),
 CHECK((accepted_digest IS NULL)=(review IS NULL)),
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,
 FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member,FOREIGN KEY(household_id,device_id) REFERENCES ritc.device
);
CREATE INDEX shared_tracking_preview_expiry ON ritc.shared_tracking_preview(household_id,expires_at);
CREATE TABLE ritc.shared_tracking_source_member(
 household_id uuid NOT NULL,shop_id uuid NOT NULL,fact_id uuid NOT NULL,member_id uuid NOT NULL,
 PRIMARY KEY(household_id,shop_id,fact_id,member_id),FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,FOREIGN KEY(household_id,member_id) REFERENCES ritc.member
);
CREATE INDEX shared_tracking_source_author ON ritc.shared_tracking_source_member(household_id,member_id);
-- Exact UTF-8 label bytes, with a fixed hash domain. No trimming, case folding,
-- Unicode normalization, JSON serialization, absent/null coercion or extra text copy.
CREATE FUNCTION ritc.tracking_label_digest(label text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT SET search_path=pg_catalog AS $$
 SELECT encode(sha256(convert_to('ritc:tracking-basket-label:v1:'||label,'UTF8')),'hex')
$$;
REVOKE ALL ON FUNCTION ritc.tracking_label_digest(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.tracking_label_digest(text) TO ritc_app;
CREATE TABLE ritc.shared_tracking_basket_origin(
 household_id uuid NOT NULL,shop_id uuid NOT NULL,line_id uuid NOT NULL,label_digest text NOT NULL CHECK(label_digest ~ '^[a-f0-9]{64}$'),member_id uuid NOT NULL,
 PRIMARY KEY(household_id,shop_id,line_id,label_digest,member_id),FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,FOREIGN KEY(household_id,member_id) REFERENCES ritc.member
);
CREATE INDEX shared_tracking_basket_author ON ritc.shared_tracking_basket_origin(household_id,member_id);
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['shared_tracking_revision','shared_tracking_adoption','shared_tracking_preview','shared_tracking_source_member','shared_tracking_basket_origin'] LOOP
  EXECUTE format('ALTER TABLE ritc.%I ENABLE ROW LEVEL SECURITY',t);EXECUTE format('ALTER TABLE ritc.%I FORCE ROW LEVEL SECURITY',t);
  EXECUTE format('CREATE POLICY tenant_scope ON ritc.%I TO ritc_app USING(household_id::text=(SELECT current_setting(''app.household_id'',true))) WITH CHECK(household_id::text=(SELECT current_setting(''app.household_id'',true)))',t);
  EXECUTE format('GRANT SELECT,INSERT ON ritc.%I TO ritc_app',t);
  IF t<>'shared_tracking_preview' THEN EXECUTE format('CREATE TRIGGER tracking_immutable BEFORE UPDATE OR DELETE ON ritc.%I FOR EACH ROW EXECUTE FUNCTION ritc.immutable_row()',t);END IF;
 END LOOP;
END $$;
GRANT DELETE ON ritc.shared_tracking_preview TO ritc_app;
GRANT UPDATE(accepted_digest,review) ON ritc.shared_tracking_preview TO ritc_app;
-- Bootstrap existing legacy/v1 snapshots before any new first-adoption state is
-- captured. This records provenance, never promotes old Undo/acceptance authority.
INSERT INTO ritc.shared_tracking_basket_origin(household_id,shop_id,line_id,label_digest,member_id)
 SELECT s.household_id,s.shop_id,(l->>'lineId')::uuid,ritc.tracking_label_digest(l->>'originalItem'),o.actor_id
 FROM ritc.shop_snapshot s JOIN ritc.operation o USING(household_id,operation_id),jsonb_array_elements(COALESCE(s.snapshot->'lines','[]')) l
 WHERE jsonb_typeof(l->'originalItem')='string' AND l->>'lineId' IS NOT NULL
 UNION
 SELECT s.household_id,s.shop_id,k.line_id,ritc.tracking_label_digest(l->>'originalItem'),r.author_id
 FROM ritc.shop_snapshot s JOIN ritc.request_link k USING(household_id,shop_id) JOIN ritc.request r USING(household_id,request_id),jsonb_array_elements(COALESCE(s.snapshot->'lines','[]')) l
 WHERE l->>'lineId'=k.line_id::text AND jsonb_typeof(l->'originalItem')='string' AND l->>'originalItem'=r.original_item
 ON CONFLICT DO NOTHING;
-- operation is inserted after its snapshot and request route mutation. Capturing
-- here covers create/change/copy/price-only/freeze/reopen/placement identically,
-- even when tracking is disabled. The earlier transaction's provenance already
-- exists before first-adoption mutation; both records roll back with the command.
CREATE FUNCTION ritc.remember_tracking_basket_origin() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 INSERT INTO ritc.shared_tracking_basket_origin(household_id,shop_id,line_id,label_digest,member_id)
 SELECT s.household_id,s.shop_id,(l->>'lineId')::uuid,ritc.tracking_label_digest(l->>'originalItem'),NEW.actor_id
 FROM ritc.shop_snapshot s,jsonb_array_elements(COALESCE(s.snapshot->'lines','[]')) l
 WHERE s.household_id=NEW.household_id AND s.operation_id=NEW.operation_id AND jsonb_typeof(l->'originalItem')='string' AND l->>'lineId' IS NOT NULL
 UNION
 SELECT s.household_id,s.shop_id,k.line_id,ritc.tracking_label_digest(l->>'originalItem'),r.author_id
 FROM ritc.shop_snapshot s JOIN ritc.request_link k USING(household_id,shop_id) JOIN ritc.request r USING(household_id,request_id),jsonb_array_elements(COALESCE(s.snapshot->'lines','[]')) l
 WHERE s.household_id=NEW.household_id AND s.operation_id=NEW.operation_id AND l->>'lineId'=k.line_id::text AND jsonb_typeof(l->'originalItem')='string' AND l->>'originalItem'=r.original_item
 ON CONFLICT DO NOTHING;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ritc.remember_tracking_basket_origin() FROM PUBLIC;
CREATE TRIGGER remember_tracking_basket_origin AFTER INSERT ON ritc.operation FOR EACH ROW EXECUTE FUNCTION ritc.remember_tracking_basket_origin();
-- Used only by the worker for exact label fields. A later independent rename on
-- the same line does not match an earlier author's different label hash.
CREATE FUNCTION ritc.tracking_erased_label(line_id text,label text,origins jsonb) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $$
 SELECT label IS NOT NULL AND EXISTS(SELECT 1 FROM jsonb_array_elements(origins) o WHERE o->>'lineId'=line_id AND o->>'labelDigest'=ritc.tracking_label_digest(label))
$$;
REVOKE ALL ON FUNCTION ritc.tracking_erased_label(text,text,jsonb) FROM PUBLIC;
-- Graph line names are copied from basket labels. A manual contribution's
-- productName/originalText are separately authored fields, even when equal to
-- that label; string equality does not transfer authorship or erasure scope.
CREATE FUNCTION ritc.tracking_redact_label_copies(g jsonb,origins jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE ls jsonb;
BEGIN
 SELECT COALESCE(jsonb_agg(CASE WHEN ritc.tracking_erased_label(x->>'id',x->>'name',origins) THEN jsonb_set(x,'{name}','"Removed item"') ELSE x END ORDER BY ord),'[]') INTO ls
 FROM jsonb_array_elements(g->'lines') WITH ORDINALITY xs(x,ord);
 RETURN jsonb_set(g,'{lines}',ls);
END $$;
REVOKE ALL ON FUNCTION ritc.tracking_redact_label_copies(jsonb,jsonb) FROM PUBLIC;
-- Only the already-authorized privacy worker may replace immutable evidence with
-- a surviving projection. This helper is never a client-supplied restoration API.
CREATE FUNCTION ritc.tracking_survivors(s jsonb,facts uuid[],sources uuid[],edge_ids uuid[],line_ids uuid[],labels jsonb,privacy integer,erased_at text) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE g jsonb;catalog jsonb;bindings jsonb;unbound jsonb;cs jsonb;es jsonb;ls jsonb;bs jsonb;legacy jsonb;
BEGIN
 s=jsonb_set(s,'{graph}',ritc.tracking_redact_label_copies(s->'graph',labels));
 SELECT COALESCE(jsonb_agg(x ORDER BY ord),'[]') INTO catalog FROM jsonb_array_elements(s->'catalog') WITH ORDINALITY AS xs(x,ord) WHERE NOT((x->>'id')::uuid=ANY(facts));
 SELECT COALESCE(jsonb_agg(x ORDER BY ord),'[]') INTO bindings FROM jsonb_array_elements(s->'bindings') WITH ORDINALITY AS xs(x,ord) WHERE NOT((x->>'factId')::uuid=ANY(facts) OR (x->>'contributionId')::uuid=ANY(sources));
 SELECT COALESCE(jsonb_agg(x ORDER BY ord),'[]') INTO unbound FROM jsonb_array_elements(s->'unbound') WITH ORDINALITY AS xs(x,ord) WHERE NOT((x->>'factId')::uuid=ANY(facts)) AND (x->'transferred'='null'::jsonb OR NOT((x#>>'{transferred,id}')::uuid=ANY(sources)));
 -- If the actor's copied row is erased but the authoritative source survives,
 -- retain that fact as genuinely unbound, never with its erased transfer proof.
 SELECT unbound || COALESCE(jsonb_agg(jsonb_build_object('factId',f->>'id','transferred',NULL) ORDER BY ord),'[]') INTO unbound
 FROM jsonb_array_elements(catalog) WITH ORDINALITY AS fs(f,ord) WHERE NOT EXISTS(SELECT 1 FROM jsonb_array_elements(bindings) b WHERE b->>'factId'=f->>'id')
 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(unbound) u WHERE u->>'factId'=f->>'id');
 SELECT COALESCE(jsonb_agg(x ORDER BY ord),'[]') INTO cs FROM jsonb_array_elements(s#>'{graph,contributions}') WITH ORDINALITY AS xs(x,ord)
 WHERE NOT((x->>'id')::uuid=ANY(sources)) AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(s->'bindings') b WHERE (b->>'factId')::uuid=ANY(facts) AND b->>'contributionId'=x->>'id');
 SELECT COALESCE(jsonb_agg(x ORDER BY ord),'[]') INTO es FROM jsonb_array_elements(s#>'{graph,edges}') WITH ORDINALITY AS xs(x,ord)
 WHERE NOT((x->>'id')::uuid=ANY(edge_ids)) AND EXISTS(SELECT 1 FROM jsonb_array_elements(cs) c WHERE c->>'id'=x->>'demandId') AND EXISTS(SELECT 1 FROM jsonb_array_elements(cs) c WHERE c->>'id'=x->>'supplyId');
 SELECT COALESCE(jsonb_agg(CASE WHEN x->'trashedAt'='null'::jsonb AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(cs) c WHERE c->>'lineId'=x->>'id' AND c->'removedAt'='null'::jsonb)
 THEN jsonb_set(CASE WHEN ((x->>'id')::uuid=ANY(line_ids) OR ritc.tracking_erased_label(x->>'id',x->>'name',labels)) THEN jsonb_set(x,'{name}','"Removed item"') ELSE x END,'{trashedAt}',to_jsonb(erased_at))
 ELSE CASE WHEN ((x->>'id')::uuid=ANY(line_ids) OR ritc.tracking_erased_label(x->>'id',x->>'name',labels)) THEN jsonb_set(x,'{name}','"Removed item"') ELSE x END END ORDER BY ord),'[]') INTO ls FROM jsonb_array_elements(s#>'{graph,lines}') WITH ORDINALITY AS xs(x,ord);
 SELECT COALESCE(jsonb_agg(CASE WHEN ((x->>'id')::uuid=ANY(line_ids) OR ritc.tracking_erased_label(x->>'id',x->>'name',labels)) THEN jsonb_set(x,'{name}','"Removed item"') ELSE x END ORDER BY ord),'[]') INTO bs FROM jsonb_array_elements(s->'basket') WITH ORDINALITY AS xs(x,ord);
 SELECT COALESCE(jsonb_agg(x->'id' ORDER BY ord),'[]') INTO legacy FROM jsonb_array_elements(bs) WITH ORDINALITY AS xs(x,ord) WHERE NOT EXISTS(SELECT 1 FROM jsonb_array_elements(ls) l WHERE l->>'id'=x->>'id' AND l->'trashedAt'='null'::jsonb);
 g=jsonb_set(jsonb_set(jsonb_set(s->'graph','{contributions}',cs),'{edges}',es),'{lines}',ls);
 RETURN (s-'packReviews') || jsonb_build_object('privacyRevision',privacy,'catalog',catalog,'bindings',bindings,'unbound',unbound,'graph',g,'basket',bs,'legacyLineIds',legacy);
END $$;
REVOKE ALL ON FUNCTION ritc.tracking_survivors(jsonb,uuid[],uuid[],uuid[],uuid[],jsonb,integer,text) FROM PUBLIC;
ALTER FUNCTION ritc.privacy_erase_extension(uuid,uuid) RENAME TO privacy_erase_before_tracking;
CREATE FUNCTION ritc.privacy_erase_extension(h uuid,m uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE target record;r record;fs uuid[];cs uuid[];es uuid[];ls uuid[];labels jsonb;p integer;survivor jsonb;old_digest text;erased_at text=to_char(clock_timestamp() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
BEGIN
 IF NOT ritc.privacy_erasure_authorized() THEN
  -- Preserve prior no-op delegation for unrelated legacy helper erasure. The
  -- older chain retains its own checks; this branch mutates no new evidence.
  IF NOT EXISTS(SELECT 1 FROM ritc.shared_tracking_preview WHERE household_id=h)
   AND NOT EXISTS(SELECT 1 FROM ritc.shared_tracking_source_member WHERE household_id=h AND member_id=m)
   AND NOT EXISTS(SELECT 1 FROM ritc.shared_demand_source_member d JOIN ritc.shared_tracking_revision t USING(household_id,shop_id) WHERE d.household_id=h AND d.member_id=m)
   AND NOT EXISTS(SELECT 1 FROM ritc.shared_tracking_basket_origin o JOIN ritc.shared_demand_revision d USING(household_id,shop_id) WHERE o.household_id=h AND o.member_id=m)
  THEN PERFORM ritc.privacy_erase_before_tracking(h,m);RETURN;END IF;
  RAISE EXCEPTION 'erasure authority required';
 END IF;
 -- Keep the existing broad transient invalidation, including uncommitted copies
 -- with no origin index yet. No early return based only on graph membership.
 DELETE FROM ritc.shared_tracking_preview WHERE household_id=h;
 PERFORM ritc.privacy_erase_before_tracking(h,m);
 FOR target IN SELECT DISTINCT shop_id FROM ritc.shared_tracking_source_member WHERE household_id=h AND member_id=m
 UNION SELECT DISTINCT d.shop_id FROM ritc.shared_demand_source_member d JOIN ritc.shared_tracking_revision t USING(household_id,shop_id) WHERE d.household_id=h AND d.member_id=m
 UNION SELECT DISTINCT o.shop_id FROM ritc.shared_tracking_basket_origin o JOIN ritc.shared_demand_revision t USING(household_id,shop_id) WHERE o.household_id=h AND o.member_id=m LOOP
  SELECT COALESCE(array_agg(fact_id),'{}') INTO fs FROM ritc.shared_tracking_source_member WHERE household_id=h AND shop_id=target.shop_id AND member_id=m;
  SELECT COALESCE(array_agg(entity_id) FILTER(WHERE entity_kind='contribution'),'{}'),COALESCE(array_agg(entity_id) FILTER(WHERE entity_kind='edge'),'{}'),COALESCE(array_agg(entity_id) FILTER(WHERE entity_kind='line'),'{}') INTO cs,es,ls
   FROM ritc.shared_demand_source_member WHERE household_id=h AND shop_id=target.shop_id AND member_id=m;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('lineId',line_id,'labelDigest',label_digest)),'[]') INTO labels FROM ritc.shared_tracking_basket_origin WHERE household_id=h AND shop_id=target.shop_id AND member_id=m;
  -- Canonical graph history must match the redacted tracking copy, including
  -- removed manual rows. Digest/receipt loss is deliberate; old proof cannot replay.
  UPDATE ritc.shared_demand_revision SET graph=ritc.tracking_redact_label_copies(graph,labels),graph_digest=NULL,receipt=NULL,pack_review=NULL WHERE household_id=h AND shop_id=target.shop_id;
  UPDATE ritc.basket_line SET original_item='Removed item' WHERE household_id=h AND shop_id=target.shop_id AND ritc.tracking_erased_label(line_id::text,original_item,labels);
  UPDATE ritc.shop_snapshot SET snapshot=jsonb_set(snapshot,'{lines}',COALESCE((SELECT jsonb_agg(CASE WHEN ritc.tracking_erased_label(x->>'lineId',x->>'originalItem',labels) THEN jsonb_set(x,'{originalItem}','"Removed item"') ELSE x END ORDER BY ord) FROM jsonb_array_elements(COALESCE(snapshot->'lines','[]')) WITH ORDINALITY xs(x,ord)),'[]')) WHERE household_id=h AND shop_id=target.shop_id;
  DELETE FROM ritc.operation_response o USING ritc.shared_demand_revision d WHERE (o.household_id,o.operation_id)=(d.household_id,d.operation_id) AND d.household_id=h AND d.shop_id=target.shop_id;
  UPDATE ritc.operation o SET payload_digest=repeat('0',64) FROM ritc.shared_demand_revision d WHERE (o.household_id,o.operation_id)=(d.household_id,d.operation_id) AND d.household_id=h AND d.shop_id=target.shop_id;
  UPDATE ritc.shop SET tracking_privacy_revision=tracking_privacy_revision+1,demand_review_required=true,revision=revision+1 WHERE household_id=h AND shop_id=target.shop_id RETURNING tracking_privacy_revision INTO p;
  FOR r IN SELECT * FROM ritc.shared_tracking_revision WHERE household_id=h AND shop_id=target.shop_id LOOP
   old_digest=COALESCE(r.state_digest,r.projection->>'invalidatedStateDigest');
   survivor=ritc.tracking_survivors(COALESCE(r.state,r.projection->'state'),fs,cs,es,ls,labels,p,erased_at);
   UPDATE ritc.shared_tracking_revision SET state=NULL,state_digest=NULL,review=NULL,privacy_revision=p,
    projection=jsonb_build_object('schemaVersion',1,'status','reviewRequired','invalidatedStateDigest',old_digest,'previousPrivacyRevision',p-1,'state',survivor)
    WHERE household_id=h AND shop_id=target.shop_id AND shop_revision=r.shop_revision;
  END LOOP;
  -- A null lineage cannot ever be promoted back into a compensating operation.
  UPDATE ritc.shared_tracking_adoption SET evidence=NULL,evidence_digest=NULL,store_basis=NULL WHERE household_id=h AND shop_id=target.shop_id;
  DELETE FROM ritc.operation_response o USING ritc.shared_tracking_revision t WHERE (o.household_id,o.operation_id)=(t.household_id,t.operation_id) AND t.household_id=h AND t.shop_id=target.shop_id;
  UPDATE ritc.operation o SET payload_digest=repeat('0',64) FROM ritc.shared_tracking_revision t WHERE (o.household_id,o.operation_id)=(t.household_id,t.operation_id) AND t.household_id=h AND t.shop_id=target.shop_id;
  UPDATE ritc.shop_snapshot SET snapshot=(snapshot-'trackingSeal') || CASE WHEN snapshot ? 'tracking' THEN jsonb_build_object('tracking',jsonb_build_object('schemaVersion',2,'status','reviewRequired','digest',NULL)) ELSE '{}'::jsonb END,digest=repeat('0',64)
   WHERE household_id=h AND shop_id=target.shop_id;
  DELETE FROM ritc.dated_cook_copy WHERE household_id=h AND shop_id=target.shop_id;
  PERFORM ritc.redact_meal_recoveries(h,NULL,target.shop_id);PERFORM ritc.redact_accepted_fallbacks(h,NULL,target.shop_id);PERFORM ritc.erase_confirmed_order(h,target.shop_id);
 END LOOP;
 -- Short-label hashes are dictionary-testable, not anonymous. They are needed
 -- through projection only; a signed restore has its own pre-erasure index copy.
 DELETE FROM ritc.shared_tracking_basket_origin WHERE household_id=h AND member_id=m;
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_extension(uuid,uuid) FROM PUBLIC;
