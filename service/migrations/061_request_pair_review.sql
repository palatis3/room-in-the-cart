-- A shopper records a relationship between two still-open requests. Neither request is fulfilled.
CREATE TABLE ritc.request_pair_review (
 household_id uuid NOT NULL, shop_id uuid NOT NULL, preview_id uuid NOT NULL,
 request_id uuid NOT NULL, request_revision integer NOT NULL CHECK (request_revision > 0),
 other_id uuid NOT NULL, other_revision integer NOT NULL CHECK (other_revision > 0),
 relationship text NOT NULL CHECK (relationship IN ('sameItem','additionalQuantity')),
 operation_id uuid, undo_operation_id uuid, invalidated boolean NOT NULL DEFAULT false,
 PRIMARY KEY (household_id,preview_id),
 UNIQUE (household_id,operation_id), UNIQUE (household_id,undo_operation_id),
 CHECK (request_id <> other_id), CHECK (undo_operation_id IS NULL OR operation_id IS NOT NULL),
 FOREIGN KEY (household_id,preview_id) REFERENCES ritc.preview ON DELETE CASCADE,
 FOREIGN KEY (household_id,request_id) REFERENCES ritc.request ON DELETE CASCADE,
 FOREIGN KEY (household_id,other_id) REFERENCES ritc.request ON DELETE CASCADE,
 FOREIGN KEY (household_id,operation_id) REFERENCES ritc.operation DEFERRABLE INITIALLY DEFERRED,
 FOREIGN KEY (household_id,undo_operation_id) REFERENCES ritc.operation DEFERRABLE INITIALLY DEFERRED
);
CREATE UNIQUE INDEX request_pair_current ON ritc.request_pair_review
 (household_id,least(request_id,other_id),greatest(request_id,other_id))
 WHERE operation_id IS NOT NULL AND undo_operation_id IS NULL AND NOT invalidated;
CREATE INDEX request_pair_first ON ritc.request_pair_review(household_id,request_id);
CREATE INDEX request_pair_other ON ritc.request_pair_review(household_id,other_id);
ALTER TABLE ritc.request_pair_review ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.request_pair_review FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON ritc.request_pair_review TO ritc_app
 USING(household_id::text=(SELECT current_setting('app.household_id',true)))
 WITH CHECK(household_id::text=(SELECT current_setting('app.household_id',true)));
GRANT SELECT, INSERT ON ritc.request_pair_review TO ritc_app;
GRANT UPDATE(operation_id,undo_operation_id) ON ritc.request_pair_review TO ritc_app;

CREATE FUNCTION ritc.retire_request_pairs() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NEW.status='withdrawn' THEN
   DELETE FROM ritc.request_pair_review WHERE household_id=NEW.household_id AND NEW.request_id IN (request_id,other_id);
 ELSE
   UPDATE ritc.request_pair_review SET invalidated=true WHERE household_id=NEW.household_id AND NEW.request_id IN (request_id,other_id) AND NOT invalidated;
 END IF;
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION ritc.retire_request_pairs() FROM PUBLIC;
CREATE TRIGGER retire_request_pairs AFTER UPDATE OF revision ON ritc.request
 FOR EACH ROW WHEN (OLD.revision IS DISTINCT FROM NEW.revision) EXECUTE FUNCTION ritc.retire_request_pairs();

CREATE FUNCTION ritc.erase_request_pair_review() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 DELETE FROM ritc.preview WHERE household_id=OLD.household_id AND (preview_id=OLD.preview_id OR
   (decision->>'choice'='undoRequestPair' AND decision->>'operationId'=OLD.operation_id::text));
 DELETE FROM ritc.operation_response WHERE household_id=OLD.household_id AND operation_id IN (OLD.operation_id,OLD.undo_operation_id);
 IF ritc.privacy_erasure_authorized() THEN
   UPDATE ritc.operation SET payload_digest=repeat('0',64) WHERE household_id=OLD.household_id AND operation_id IN (OLD.operation_id,OLD.undo_operation_id);
 END IF;
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION ritc.erase_request_pair_review() FROM PUBLIC;
CREATE TRIGGER erase_request_pair_review AFTER DELETE ON ritc.request_pair_review
 FOR EACH ROW EXECUTE FUNCTION ritc.erase_request_pair_review();
