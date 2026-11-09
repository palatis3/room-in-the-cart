-- Adapted from the locally generated shared_demand_graph migration to the
-- repository's numbered/checksum runner. Private service schema; no Data API grants.
ALTER TABLE ritc.shop ADD COLUMN demand_revision integer CHECK(demand_revision>0),
 ADD COLUMN demand_review_required boolean NOT NULL DEFAULT false;
GRANT UPDATE(demand_revision,demand_review_required) ON ritc.shop TO ritc_app;
CREATE TABLE ritc.shared_demand_revision (
 household_id uuid NOT NULL,shop_id uuid NOT NULL,revision integer NOT NULL CHECK(revision>0),
 predecessor integer,shop_revision integer NOT NULL,authority_epoch integer NOT NULL,
 operation_id uuid NOT NULL,actor_id uuid NOT NULL,device_id uuid NOT NULL,created_at timestamptz NOT NULL,
 graph jsonb NOT NULL,graph_digest text,receipt jsonb,pack_review jsonb,
 PRIMARY KEY(household_id,shop_id,revision),UNIQUE(household_id,operation_id),
 CHECK((revision=1 AND predecessor IS NULL) OR (revision>1 AND predecessor IS NOT NULL AND predecessor=revision-1)),
 CHECK(jsonb_typeof(graph)='object' AND (graph->>'schemaVersion') IS NOT NULL AND graph->>'schemaVersion'='1'
  AND (graph->>'revision') IS NOT NULL AND (graph->>'revision')::integer=revision
  AND (graph->>'householdId') IS NOT NULL AND (graph->>'householdId')::uuid=household_id
  AND (graph->>'shopId') IS NOT NULL AND (graph->>'shopId')::uuid=shop_id),
 CHECK(graph_digest IS NULL OR graph_digest ~ '^[0-9a-f]{64}$'),
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,
 FOREIGN KEY(household_id,shop_id,predecessor) REFERENCES ritc.shared_demand_revision,
 FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member,
 FOREIGN KEY(household_id,device_id) REFERENCES ritc.device,
 FOREIGN KEY(household_id,operation_id) REFERENCES ritc.operation DEFERRABLE INITIALLY DEFERRED
);
ALTER TABLE ritc.shop ADD FOREIGN KEY(household_id,shop_id,demand_revision)
 REFERENCES ritc.shared_demand_revision DEFERRABLE INITIALLY DEFERRED;
CREATE TABLE ritc.shared_demand_preview (
 household_id uuid NOT NULL,shop_id uuid NOT NULL,preview_id uuid NOT NULL,operation_id uuid NOT NULL,
 actor_id uuid NOT NULL,device_id uuid NOT NULL,authority_epoch integer NOT NULL,
 shop_revision integer NOT NULL,graph_revision integer NOT NULL,graph_digest text NOT NULL,
 intent jsonb NOT NULL,accepted_digest text NOT NULL,created_at timestamptz NOT NULL,expires_at timestamptz NOT NULL,
 PRIMARY KEY(household_id,preview_id),UNIQUE(household_id,operation_id),
 CHECK(expires_at>created_at AND expires_at<=created_at+interval '10 minutes'),
 CHECK(accepted_digest ~ '^[0-9a-f]{64}$' AND graph_digest ~ '^[0-9a-f]{64}$'),
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,
 FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member,FOREIGN KEY(household_id,device_id) REFERENCES ritc.device
);
CREATE INDEX shared_demand_preview_expiry ON ritc.shared_demand_preview(household_id,expires_at);
-- Content-free origin dependencies are never replaced by the last editor.
CREATE TABLE ritc.shared_demand_source_member (
 household_id uuid NOT NULL,shop_id uuid NOT NULL,entity_id uuid NOT NULL,
 entity_kind text NOT NULL CHECK(entity_kind IN ('line','contribution','edge')),member_id uuid NOT NULL,
 PRIMARY KEY(household_id,shop_id,entity_id,entity_kind,member_id),
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,FOREIGN KEY(household_id,member_id) REFERENCES ritc.member
);
CREATE INDEX shared_demand_member ON ritc.shared_demand_source_member(household_id,member_id);
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['shared_demand_revision','shared_demand_preview','shared_demand_source_member'] LOOP
  EXECUTE format('ALTER TABLE ritc.%I ENABLE ROW LEVEL SECURITY',t);
  EXECUTE format('ALTER TABLE ritc.%I FORCE ROW LEVEL SECURITY',t);
  EXECUTE format('CREATE POLICY tenant_scope ON ritc.%I TO ritc_app USING(household_id::text=(SELECT current_setting(''app.household_id'',true))) WITH CHECK(household_id::text=(SELECT current_setting(''app.household_id'',true)))',t);
  EXECUTE format('GRANT SELECT,INSERT ON ritc.%I TO ritc_app',t);
 END LOOP;
END $$;
GRANT DELETE ON ritc.shared_demand_preview TO ritc_app;
CREATE TRIGGER shared_demand_immutable BEFORE UPDATE OR DELETE ON ritc.shared_demand_revision FOR EACH ROW EXECUTE FUNCTION ritc.immutable_row();
CREATE TRIGGER shared_demand_origin_immutable BEFORE UPDATE OR DELETE ON ritc.shared_demand_source_member FOR EACH ROW EXECUTE FUNCTION ritc.immutable_row();

-- Privacy is a separate, lease-authorized projection, never ordinary source removal.
-- Erase all historical copies of a source while retaining unrelated commitments
-- and used IDs. A redacted head requires explicit review; no older head is revived.
CREATE FUNCTION ritc.erase_shared_demand(h uuid,m uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE target record;r record;cs uuid[];es uuid[];ls uuid[];remaining jsonb;links jsonb;line_rows jsonb;
BEGIN
 -- Legacy members with no graph dependency or transient preview require no new
 -- mutation. Existing extension behavior remains unchanged for those records.
 IF NOT EXISTS(SELECT 1 FROM ritc.shared_demand_source_member WHERE household_id=h AND member_id=m)
  AND NOT EXISTS(SELECT 1 FROM ritc.shared_demand_preview WHERE household_id=h) THEN RETURN; END IF;
 IF NOT ritc.privacy_erasure_authorized() THEN RAISE EXCEPTION 'erasure authority required'; END IF;
 -- A different shopper may hold uncommitted copied source text with no persisted
 -- origin row yet. Invalidate all transient household previews on any erasure.
 DELETE FROM ritc.shared_demand_preview WHERE household_id=h;
 FOR target IN SELECT DISTINCT shop_id FROM ritc.shared_demand_source_member WHERE household_id=h AND member_id=m LOOP
  SELECT COALESCE(array_agg(entity_id) FILTER(WHERE entity_kind='contribution'),'{}'),
   COALESCE(array_agg(entity_id) FILTER(WHERE entity_kind='edge'),'{}'),COALESCE(array_agg(entity_id) FILTER(WHERE entity_kind='line'),'{}')
   INTO cs,es,ls FROM ritc.shared_demand_source_member WHERE household_id=h AND shop_id=target.shop_id AND member_id=m;
  DELETE FROM ritc.shared_demand_preview WHERE household_id=h AND shop_id=target.shop_id;
  FOR r IN SELECT * FROM ritc.shared_demand_revision WHERE household_id=h AND shop_id=target.shop_id LOOP
   SELECT COALESCE(jsonb_agg(c),'[]') INTO remaining FROM jsonb_array_elements(r.graph->'contributions') c WHERE NOT((c->>'id')::uuid=ANY(cs));
   SELECT COALESCE(jsonb_agg(e),'[]') INTO links FROM jsonb_array_elements(r.graph->'edges') e WHERE NOT((e->>'id')::uuid=ANY(es) OR (e->>'demandId')::uuid=ANY(cs) OR (e->>'supplyId')::uuid=ANY(cs));
   SELECT COALESCE(jsonb_agg(CASE WHEN (l->>'id')::uuid=ANY(ls) THEN jsonb_set(l,'{name}','"Removed item"') ELSE l END),'[]') INTO line_rows FROM jsonb_array_elements(r.graph->'lines') l;
   UPDATE ritc.shared_demand_revision SET graph=jsonb_set(jsonb_set(jsonb_set(graph,'{contributions}',remaining),'{edges}',links),'{lines}',line_rows),graph_digest=NULL,receipt=NULL,pack_review=NULL
    WHERE household_id=h AND shop_id=target.shop_id AND revision=r.revision;
  END LOOP;
  DELETE FROM ritc.operation_response o USING ritc.shared_demand_revision d WHERE (o.household_id,o.operation_id)=(d.household_id,d.operation_id) AND d.household_id=h AND d.shop_id=target.shop_id;
  UPDATE ritc.operation o SET payload_digest=repeat('0',64) FROM ritc.shared_demand_revision d WHERE (o.household_id,o.operation_id)=(d.household_id,d.operation_id) AND d.household_id=h AND d.shop_id=target.shop_id;
  -- Current and historical basket labels may have been copied by a different shopper.
  UPDATE ritc.basket_line SET original_item='Removed item' WHERE household_id=h AND shop_id=target.shop_id AND line_id=ANY(ls);
  UPDATE ritc.shop_snapshot SET snapshot=jsonb_set(snapshot,'{lines}',COALESCE((SELECT jsonb_agg(CASE WHEN (v->>'lineId')::uuid=ANY(ls) THEN jsonb_set(v,'{originalItem}','"Removed item"') ELSE v END) FROM jsonb_array_elements(snapshot->'lines') v),'[]')),digest=repeat('0',64) WHERE household_id=h AND shop_id=target.shop_id AND EXISTS(SELECT 1 FROM jsonb_array_elements(snapshot->'lines') v WHERE (v->>'lineId')::uuid=ANY(ls));
  -- Sealed consumers must not treat the erased graph as its former accepted basis.
  UPDATE ritc.shop_snapshot SET digest=repeat('0',64) WHERE household_id=h AND shop_id=target.shop_id AND snapshot ? 'demand';
  DELETE FROM ritc.dated_cook_copy WHERE household_id=h AND shop_id=target.shop_id;
  PERFORM ritc.redact_meal_recoveries(h,NULL,target.shop_id);
  PERFORM ritc.redact_accepted_fallbacks(h,NULL,target.shop_id);
  PERFORM ritc.erase_confirmed_order(h,target.shop_id);
  UPDATE ritc.shop SET demand_review_required=true,revision=revision+1 WHERE household_id=h AND shop_id=target.shop_id;
 END LOOP;
END $$;
REVOKE ALL ON FUNCTION ritc.erase_shared_demand(uuid,uuid) FROM PUBLIC;
ALTER FUNCTION ritc.privacy_erase_extension(uuid,uuid) RENAME TO privacy_erase_before_shared_demand;
CREATE FUNCTION ritc.privacy_erase_extension(h uuid,m uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 PERFORM ritc.erase_shared_demand(h,m);
 PERFORM ritc.privacy_erase_before_shared_demand(h,m);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_extension(uuid,uuid) FROM PUBLIC;
