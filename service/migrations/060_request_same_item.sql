-- Store references only. The original request and authoritative meal / purchase retain their own facts.
CREATE TABLE ritc.request_same_item (
 household_id uuid NOT NULL, shop_id uuid NOT NULL, preview_id uuid NOT NULL,
 request_id uuid NOT NULL, request_revision integer NOT NULL CHECK (request_revision > 0),
 prior_status text NOT NULL CHECK (prior_status IN ('pending','clarified')),
 meal_occurrence uuid, meal_revision integer, purchase_operation uuid,
 operation_id uuid, undo_operation_id uuid, invalidated boolean NOT NULL DEFAULT false,
 PRIMARY KEY(household_id,preview_id),
 UNIQUE(household_id,operation_id), UNIQUE(household_id,undo_operation_id),
 CHECK ((meal_occurrence IS NULL)=(meal_revision IS NULL)),
 CHECK ((meal_occurrence IS NULL)<>(purchase_operation IS NULL)),
 CHECK (undo_operation_id IS NULL OR operation_id IS NOT NULL),
 FOREIGN KEY(household_id,preview_id) REFERENCES ritc.preview ON DELETE CASCADE,
 FOREIGN KEY(household_id,request_id) REFERENCES ritc.request ON DELETE CASCADE,
 FOREIGN KEY(household_id,shop_id,meal_occurrence,meal_revision) REFERENCES ritc.shared_meal_revision ON DELETE CASCADE,
 FOREIGN KEY(household_id,purchase_operation) REFERENCES ritc.request_purchase_review ON DELETE CASCADE,
 FOREIGN KEY(household_id,operation_id) REFERENCES ritc.operation DEFERRABLE INITIALLY DEFERRED,
 FOREIGN KEY(household_id,undo_operation_id) REFERENCES ritc.operation DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX request_same_item_source_meal ON ritc.request_same_item(household_id,shop_id,meal_occurrence,meal_revision);
CREATE INDEX request_same_item_source_purchase ON ritc.request_same_item(household_id,purchase_operation);
CREATE INDEX request_same_item_request ON ritc.request_same_item(household_id,request_id,request_revision);
ALTER TABLE ritc.request_same_item ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.request_same_item FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON ritc.request_same_item TO ritc_app
 USING(household_id::text=(SELECT current_setting('app.household_id',true)))
 WITH CHECK(household_id::text=(SELECT current_setting('app.household_id',true)));
GRANT SELECT,INSERT,UPDATE ON ritc.request_same_item TO ritc_app;

CREATE FUNCTION ritc.reopen_same_item_request(h uuid,s uuid,r uuid,original_revision integer,prior text,applied uuid,undone uuid) RETURNS void
LANGUAGE sql SET search_path=pg_catalog AS $$
 UPDATE ritc.request SET status=prior,revision=revision+1,
  route=CASE WHEN EXISTS (SELECT FROM ritc.shop WHERE household_id=h AND shop_id=s AND phase IN ('placed','closed'))
             THEN 'next' ELSE route END
 WHERE applied IS NOT NULL AND undone IS NULL AND household_id=h AND shop_id=s AND request_id=r
   AND revision=original_revision+1 AND status='handled';
$$;
REVOKE ALL ON FUNCTION ritc.reopen_same_item_request(uuid,uuid,uuid,integer,text,uuid,uuid) FROM PUBLIC;
CREATE FUNCTION ritc.erase_same_item_review() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 DELETE FROM ritc.preview WHERE household_id=OLD.household_id AND
  (preview_id=OLD.preview_id OR (decision->>'choice'='undoSameItem' AND decision->>'operationId'=OLD.operation_id::text));
 DELETE FROM ritc.operation_response WHERE household_id=OLD.household_id AND operation_id IN (OLD.operation_id,OLD.undo_operation_id);
 UPDATE ritc.operation SET payload_digest=repeat('0',64) WHERE household_id=OLD.household_id AND operation_id IN (OLD.operation_id,OLD.undo_operation_id);
 IF NOT OLD.invalidated THEN
  PERFORM ritc.reopen_same_item_request(OLD.household_id,OLD.shop_id,OLD.request_id,OLD.request_revision,
    OLD.prior_status,OLD.operation_id,OLD.undo_operation_id);
 END IF;
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION ritc.erase_same_item_review() FROM PUBLIC;
CREATE TRIGGER erase_same_item_review AFTER DELETE ON ritc.request_same_item
 FOR EACH ROW EXECUTE FUNCTION ritc.erase_same_item_review();

-- A historical reference is retained for erasure and audit, but it cannot keep
-- another author's request handled after its source proof changes.
CREATE FUNCTION ritc.invalidate_same_item_source() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE affected record;
BEGIN
 IF TG_TABLE_NAME='request' THEN
  FOR affected IN UPDATE ritc.request_same_item e SET invalidated=true
   FROM ritc.request_purchase_review p
   WHERE (e.household_id,e.purchase_operation)=(p.household_id,p.operation_id)
    AND (p.household_id,p.shop_id,p.request_id)=(NEW.household_id,NEW.shop_id,NEW.request_id)
    AND p.request_revision<>NEW.revision AND NOT e.invalidated
   RETURNING e.*
  LOOP
   PERFORM ritc.reopen_same_item_request(affected.household_id,affected.shop_id,affected.request_id,
    affected.request_revision,affected.prior_status,affected.operation_id,affected.undo_operation_id);
  END LOOP;
 ELSE
  FOR affected IN UPDATE ritc.request_same_item SET invalidated=true
   WHERE (household_id,shop_id,meal_occurrence)=(NEW.household_id,NEW.shop_id,NEW.occurrence_id)
     AND meal_revision<NEW.revision AND NOT invalidated
   RETURNING *
  LOOP
   PERFORM ritc.reopen_same_item_request(affected.household_id,affected.shop_id,affected.request_id,
    affected.request_revision,affected.prior_status,affected.operation_id,affected.undo_operation_id);
  END LOOP;
 END IF;
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION ritc.invalidate_same_item_source() FROM PUBLIC;
CREATE TRIGGER invalidate_same_item_purchase AFTER UPDATE OF revision ON ritc.request
 FOR EACH ROW WHEN (OLD.revision IS DISTINCT FROM NEW.revision) EXECUTE FUNCTION ritc.invalidate_same_item_source();
CREATE TRIGGER invalidate_same_item_meal AFTER INSERT ON ritc.shared_meal_revision
 FOR EACH ROW EXECUTE FUNCTION ritc.invalidate_same_item_source();
