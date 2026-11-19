-- Field generations represent edit continuity. They contain no copy, hash or
-- reversible encoding of the user's wording. A new value gets a fresh ID.
CREATE SEQUENCE ritc.moderation_field_generation AS bigint;
ALTER TABLE ritc.request ADD COLUMN item_generation bigint, ADD COLUMN amount_generation bigint, ADD COLUMN question_generation bigint;
ALTER TABLE ritc.view_grant ADD COLUMN instruction_generations jsonb;

CREATE FUNCTION ritc.moderation_request_fields() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF TG_OP='INSERT' OR OLD.item_generation IS NULL OR NEW.original_item IS DISTINCT FROM OLD.original_item THEN
  NEW.item_generation:=nextval('ritc.moderation_field_generation');
 END IF;
 IF NEW.own_quantity IS NULL THEN NEW.amount_generation:=NULL;
 ELSIF TG_OP='INSERT' OR OLD.amount_generation IS NULL OR NEW.own_quantity IS DISTINCT FROM OLD.own_quantity THEN
  NEW.amount_generation:=nextval('ritc.moderation_field_generation');
 END IF;
 IF NEW.clarification IS NULL THEN NEW.question_generation:=NULL;
 ELSIF TG_OP='INSERT' OR OLD.question_generation IS NULL OR NEW.clarification IS DISTINCT FROM OLD.clarification THEN
  NEW.question_generation:=nextval('ritc.moderation_field_generation');
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER moderation_request_fields BEFORE INSERT OR UPDATE OF original_item,own_quantity,clarification ON ritc.request
 FOR EACH ROW EXECUTE FUNCTION ritc.moderation_request_fields();
UPDATE ritc.request SET original_item=original_item;
ALTER TABLE ritc.request ALTER COLUMN item_generation SET NOT NULL;

-- Cook rows do not have user-facing identities. Match unchanged rows first,
-- then a stable product label or an otherwise unchanged row whose label was
-- renamed. Identical fields in unrelated identified rows never share a token.
CREATE FUNCTION ritc.moderation_instruction_fields(previous jsonb, generations jsonb, incoming jsonb) RETURNS jsonb
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog AS $$
 WITH prior AS MATERIALIZED (
  SELECT value AS row,ordinality AS pos,generations->'items'->(ordinality::int-1) AS ids,
    count(*) OVER(PARTITION BY value->>'label') AS labels,count(*) OVER(PARTITION BY value-'label') AS bodies
  FROM jsonb_array_elements(previous->'items') WITH ORDINALITY
 ), fresh AS MATERIALIZED (
  SELECT value AS row,ordinality AS pos,count(*) OVER(PARTITION BY value->>'label') AS labels,
    count(*) OVER(PARTITION BY value-'label') AS bodies FROM jsonb_array_elements(incoming->'items') WITH ORDINALITY
 ), matched AS (
  SELECT n.*,o.row AS old_row,o.ids AS old_ids FROM fresh n LEFT JOIN LATERAL (
   SELECT p.row,p.ids FROM prior p
   WHERE p.row=n.row OR (p.labels=1 AND n.labels=1 AND p.row->>'label'=n.row->>'label')
      OR (p.bodies=1 AND n.bodies=1 AND p.row-'label'=n.row-'label')
      OR (p.pos=n.pos AND p.row->>'label'=n.row->>'label')
      OR (jsonb_array_length(previous->'items')=1 AND jsonb_array_length(incoming->'items')=1)
   ORDER BY (p.row=n.row) DESC,(p.labels=1 AND n.labels=1 AND p.row->>'label'=n.row->>'label') DESC,
      (p.bodies=1 AND n.bodies=1 AND p.row-'label'=n.row-'label') DESC,(p.pos=n.pos) DESC,p.pos LIMIT 1
  ) o ON true
 ), row_ids AS (
  SELECT n.pos,jsonb_object_agg(k,CASE WHEN n.row->>k IS NULL THEN NULL
   WHEN n.old_ids->>k IS NOT NULL AND n.old_row->>k=n.row->>k THEN (n.old_ids->>k)::bigint
   -- If a row moved and several identifying fields changed, preserve an
   -- unambiguous exact field from this same projection. Never borrow another
   -- identified row's matching common quantity when this row was corrected.
   WHEN n.old_row IS NULL THEN coalesce((
    SELECT min((p.ids->>k)::bigint) FROM prior p WHERE p.row->>k=n.row->>k
    HAVING count(*)=1 AND (SELECT count(*) FROM fresh other WHERE other.row->>k=n.row->>k)=1
   ),nextval('ritc.moderation_field_generation'))
   ELSE nextval('ritc.moderation_field_generation') END) AS ids
  FROM matched n CROSS JOIN unnest(ARRAY['label','amount','unit','action']) k GROUP BY n.pos
 )
 SELECT jsonb_build_object('shopLabel',CASE WHEN generations->>'shopLabel' IS NOT NULL AND previous->>'shopLabel'=incoming->>'shopLabel'
  THEN (generations->>'shopLabel')::bigint ELSE nextval('ritc.moderation_field_generation') END,
  'items',coalesce((SELECT jsonb_agg(ids ORDER BY pos) FROM row_ids),'[]'::jsonb))
$$;
CREATE FUNCTION ritc.set_moderation_instruction_fields() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF TG_OP='INSERT' THEN NEW.instruction_generations:=ritc.moderation_instruction_fields(NULL,NULL,NEW.projection);
 ELSIF OLD.instruction_generations IS NULL OR NEW.projection IS DISTINCT FROM OLD.projection THEN
  NEW.instruction_generations:=ritc.moderation_instruction_fields(OLD.projection,OLD.instruction_generations,NEW.projection);
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER moderation_instruction_fields BEFORE INSERT OR UPDATE OF projection ON ritc.view_grant
 FOR EACH ROW EXECUTE FUNCTION ritc.set_moderation_instruction_fields();
UPDATE ritc.view_grant SET projection=projection;
ALTER TABLE ritc.view_grant ALTER COLUMN instruction_generations SET NOT NULL;

-- Carry-forward is an explicit recorded copy by the service. Preserve a
-- matching source field through that link independently of other fields.
CREATE FUNCTION ritc.carry_moderation_request_fields() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 UPDATE ritc.request child SET
  item_generation=CASE WHEN child.original_item=parent.original_item THEN parent.item_generation ELSE child.item_generation END,
  amount_generation=CASE WHEN child.own_quantity=parent.own_quantity THEN parent.amount_generation ELSE child.amount_generation END
 FROM ritc.request parent WHERE (parent.household_id,parent.request_id)=(NEW.household_id,NEW.source_request_id)
 AND (child.household_id,child.request_id)=(NEW.household_id,NEW.target_request_id) AND child.author_id=parent.author_id;
 RETURN NEW;
END $$;
CREATE TRIGGER moderation_carry_fields AFTER INSERT ON ritc.request_carry FOR EACH ROW EXECUTE FUNCTION ritc.carry_moderation_request_fields();
-- Traverse the acyclic persisted carry chains from their roots for existing data.
WITH RECURSIVE lineage AS (
 SELECT r.household_id,r.request_id,r.author_id,r.original_item,r.own_quantity,r.item_generation,r.amount_generation
 FROM ritc.request r WHERE NOT EXISTS(SELECT FROM ritc.request_carry c WHERE (c.household_id,c.target_request_id)=(r.household_id,r.request_id))
 AND EXISTS(SELECT FROM ritc.request_carry c WHERE (c.household_id,c.source_request_id)=(r.household_id,r.request_id))
 UNION ALL SELECT r.household_id,r.request_id,r.author_id,r.original_item,r.own_quantity,
 CASE WHEN r.original_item=l.original_item THEN l.item_generation ELSE r.item_generation END,
 CASE WHEN r.own_quantity=l.own_quantity THEN l.amount_generation ELSE r.amount_generation END
 FROM lineage l JOIN ritc.request_carry c ON (c.household_id,c.source_request_id)=(l.household_id,l.request_id)
 JOIN ritc.request r ON (r.household_id,r.request_id,r.author_id)=(c.household_id,c.target_request_id,l.author_id)
)
UPDATE ritc.request r SET item_generation=l.item_generation,amount_generation=l.amount_generation
FROM lineage l WHERE (r.household_id,r.request_id)=(l.household_id,l.request_id)
AND (r.item_generation,r.amount_generation) IS DISTINCT FROM (l.item_generation,l.amount_generation);

ALTER TABLE ritc.moderation_case ADD COLUMN field_generation bigint;
CREATE TABLE ritc.moderation_removed_field(
 household_id uuid NOT NULL REFERENCES ritc.household, generation bigint NOT NULL,
 PRIMARY KEY(household_id,generation)
);
ALTER TABLE ritc.moderation_removed_field ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.moderation_removed_field FORCE ROW LEVEL SECURITY;

CREATE FUNCTION ritc.capture_moderation_field() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NEW.source_kind IN ('request','clarification') THEN
  SELECT CASE NEW.source_field WHEN 'item' THEN item_generation WHEN 'amount' THEN amount_generation WHEN 'question' THEN question_generation END
  INTO NEW.field_generation FROM ritc.request WHERE (household_id,request_id,revision)=(NEW.household_id,NEW.source_id,NEW.source_revision);
 ELSIF NEW.source_kind='instruction' THEN
  SELECT CASE WHEN NEW.source_field='shopLabel' THEN (instruction_generations->>'shopLabel')::bigint
   ELSE (instruction_generations->'items'->NEW.field_index->>NEW.source_field)::bigint END
  INTO NEW.field_generation FROM ritc.view_grant WHERE (household_id,grant_id,revision)=(NEW.household_id,NEW.source_id,NEW.source_revision);
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER moderation_capture_field BEFORE INSERT OR UPDATE OF source_revision ON ritc.moderation_case
 FOR EACH ROW EXECUTE FUNCTION ritc.capture_moderation_field();
-- Older reports bind only when their reviewed revision still exists verbatim.
UPDATE ritc.moderation_case SET source_revision=source_revision WHERE source_kind IN ('request','clarification','instruction');
CREATE FUNCTION ritc.remember_moderation_field() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NEW.resolution IN ('remove','suspend') AND NEW.field_generation IS NOT NULL THEN
  INSERT INTO ritc.moderation_removed_field VALUES(NEW.household_id,NEW.field_generation) ON CONFLICT DO NOTHING;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER moderation_remember_field AFTER UPDATE OF resolution ON ritc.moderation_case FOR EACH ROW EXECUTE FUNCTION ritc.remember_moderation_field();
INSERT INTO ritc.moderation_removed_field SELECT DISTINCT household_id,field_generation FROM ritc.moderation_case
 WHERE resolution IN ('remove','suspend') AND field_generation IS NOT NULL ON CONFLICT DO NOTHING;

CREATE FUNCTION ritc.moderation_has_removed_field(h uuid,kind text,id uuid,rev integer) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NOT EXISTS(SELECT FROM ritc.moderation_removed_field f WHERE f.household_id=h) THEN RETURN false; END IF;
 IF kind IN ('request','clarification') THEN
  RETURN EXISTS(SELECT FROM ritc.request r JOIN ritc.moderation_removed_field f ON f.household_id=r.household_id
   AND CASE WHEN kind='request' THEN f.generation IN (r.item_generation,r.amount_generation) ELSE f.generation=r.question_generation END
   WHERE (r.household_id,r.request_id,r.revision)=(h,id,rev));
 ELSIF kind='instruction' THEN
  RETURN EXISTS(SELECT FROM ritc.view_grant g CROSS JOIN LATERAL (
     SELECT (g.instruction_generations->>'shopLabel')::bigint AS generation UNION ALL
     SELECT field.value::bigint FROM jsonb_array_elements(g.instruction_generations->'items') item CROSS JOIN LATERAL jsonb_each_text(item) field
    ) current_field JOIN ritc.moderation_removed_field f ON (f.household_id,f.generation)=(h,current_field.generation)
    WHERE (g.household_id,g.grant_id,g.revision)=(h,id,rev));
 END IF;
 RETURN false;
END $$;
-- Replace in place: the previously created security-invoker views must keep
-- their binding to the same function OID.
CREATE OR REPLACE FUNCTION ritc.shared_content_visible(h uuid, viewer uuid, author uuid, kind text, source uuid, first_revision integer, current_revision integer) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT coalesce(h::text=current_setting('app.household_id',true),false) AND viewer IS NOT NULL
  AND NOT ritc.content_account_suspended(h,author)
  AND NOT EXISTS(SELECT FROM ritc.moderation_block WHERE household_id=h AND viewer_id=viewer AND author_id=author)
  AND NOT EXISTS(SELECT FROM ritc.moderation_removal WHERE household_id=h AND source_kind=kind AND source_id=source
                 AND source_revision BETWEEN coalesce(first_revision,1) AND current_revision)
  AND NOT ritc.moderation_has_removed_field(h,kind,source,current_revision)
$$;
REVOKE ALL ON FUNCTION ritc.moderation_request_fields(),ritc.moderation_instruction_fields(jsonb,jsonb,jsonb),
 ritc.set_moderation_instruction_fields(),ritc.carry_moderation_request_fields(),ritc.capture_moderation_field(),
 ritc.remember_moderation_field(),ritc.moderation_has_removed_field(uuid,text,uuid,integer) FROM PUBLIC;
