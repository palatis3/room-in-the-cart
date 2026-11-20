-- Scope one adult's request decision to the original shop, author and shopper.
CREATE TABLE ritc.trip_substitution (
 household_id uuid NOT NULL, request_id uuid NOT NULL, shop_id uuid NOT NULL,
 author_id uuid NOT NULL, shopper_id uuid NOT NULL, authority_epoch integer NOT NULL,
 revision integer NOT NULL CHECK(revision>0), choice text CHECK(choice IN ('exact','alternative','skip')),
 alternative text CHECK(length(alternative) BETWEEN 1 AND 240), client_key uuid, fingerprint text,
 PRIMARY KEY(household_id,request_id),
 CHECK((choice IS NOT DISTINCT FROM 'alternative')=(alternative IS NOT NULL)),
 FOREIGN KEY(household_id,request_id) REFERENCES ritc.request ON DELETE CASCADE,
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop ON DELETE CASCADE,
 FOREIGN KEY(household_id,author_id) REFERENCES ritc.member ON DELETE CASCADE,
 FOREIGN KEY(household_id,shopper_id) REFERENCES ritc.member ON DELETE CASCADE
);

CREATE TABLE ritc.trip_picking_permission (
 household_id uuid NOT NULL, shop_id uuid NOT NULL, permission_id uuid NOT NULL UNIQUE,
 shopper_id uuid NOT NULL, recipient_id uuid NOT NULL, authority_epoch integer NOT NULL,
 expires_at timestamptz NOT NULL, line_ids uuid[] NOT NULL,
 PRIMARY KEY(household_id,shop_id), CHECK(shopper_id<>recipient_id), CHECK(cardinality(line_ids) BETWEEN 1 AND 200),
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop ON DELETE CASCADE,
 FOREIGN KEY(household_id,shopper_id) REFERENCES ritc.member ON DELETE CASCADE,
 FOREIGN KEY(household_id,recipient_id) REFERENCES ritc.member ON DELETE CASCADE
);
-- Keep accepted quantities when a grant is replaced, independently of the participant.
-- Each label is read from the current basket only. Changed rows require a new share.
CREATE TABLE ritc.trip_picking_row (
 household_id uuid NOT NULL, shop_id uuid NOT NULL, line_id uuid NOT NULL,
 safety_id uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),
 revision integer NOT NULL DEFAULT 1 CHECK(revision>0), picked integer NOT NULL DEFAULT 0 CHECK(picked>=0),
 published_permission uuid, claimed_by uuid, last_actor uuid, last_operation uuid, last_permission uuid,
 PRIMARY KEY(household_id,shop_id,line_id),
 FOREIGN KEY(household_id,shop_id,line_id) REFERENCES ritc.basket_line ON DELETE CASCADE
);
CREATE TABLE ritc.trip_picking_operation (
 household_id uuid NOT NULL, actor_id uuid NOT NULL, device_id uuid NOT NULL, operation_id uuid NOT NULL,
 shop_id uuid NOT NULL, permission_id uuid, row_id uuid, fingerprint text NOT NULL,
 prior_picked integer, prior_claim uuid, receipt jsonb NOT NULL,
 PRIMARY KEY(household_id,actor_id,operation_id),
 FOREIGN KEY(household_id,actor_id,device_id) REFERENCES ritc.device(household_id,member_id,device_id) ON DELETE CASCADE,
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop ON DELETE CASCADE
);
CREATE INDEX trip_picking_operation_shop ON ritc.trip_picking_operation(household_id,shop_id);
CREATE INDEX trip_substitution_shop ON ritc.trip_substitution(household_id,shop_id);
ALTER TABLE ritc.moderation_case DROP CONSTRAINT moderation_case_source_kind_check,
 ADD CHECK(source_kind IN ('request','clarification','instruction','suggestion','cookCopy','productReference','substitution','pickingRow'));

DO $$ DECLARE relation text; BEGIN
 FOREACH relation IN ARRAY ARRAY['trip_substitution','trip_picking_permission','trip_picking_row','trip_picking_operation'] LOOP
  EXECUTE format('ALTER TABLE ritc.%I ENABLE ROW LEVEL SECURITY',relation);
  EXECUTE format('ALTER TABLE ritc.%I FORCE ROW LEVEL SECURITY',relation);
  EXECUTE format('CREATE POLICY tenant_scope ON ritc.%I TO ritc_app USING(household_id::text=(SELECT current_setting(''app.household_id'',true))) WITH CHECK(household_id::text=(SELECT current_setting(''app.household_id'',true)))',relation);
  EXECUTE format('GRANT SELECT,INSERT,UPDATE ON ritc.%I TO ritc_app',relation);
 END LOOP;
END $$;
GRANT DELETE ON ritc.trip_picking_permission TO ritc_app;
CREATE POLICY decision_participants ON ritc.trip_substitution AS RESTRICTIVE TO ritc_app
 USING (ritc.content_viewer() IN (author_id,shopper_id)) WITH CHECK (ritc.content_viewer() IN (author_id,shopper_id));
CREATE POLICY picking_participants ON ritc.trip_picking_permission AS RESTRICTIVE TO ritc_app
 USING (ritc.content_viewer() IN (shopper_id,recipient_id)) WITH CHECK (ritc.content_viewer() IN (shopper_id,recipient_id));
CREATE POLICY picking_row_participants ON ritc.trip_picking_row AS RESTRICTIVE TO ritc_app
 USING (EXISTS(SELECT FROM ritc.shop s WHERE (s.household_id,s.shop_id)=(trip_picking_row.household_id,trip_picking_row.shop_id)
               AND s.shopper_id=ritc.content_viewer())
   OR EXISTS(SELECT FROM ritc.trip_picking_permission p WHERE p.household_id=trip_picking_row.household_id
      AND p.shop_id=trip_picking_row.shop_id AND p.permission_id=trip_picking_row.published_permission
      AND p.recipient_id=ritc.content_viewer() AND p.expires_at>statement_timestamp() AND trip_picking_row.line_id=ANY(p.line_ids)));
CREATE POLICY picking_actor ON ritc.trip_picking_operation AS RESTRICTIVE TO ritc_app
 USING (ritc.content_viewer()=actor_id) WITH CHECK (ritc.content_viewer()=actor_id);

CREATE FUNCTION ritc.end_trip_coordination() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF TG_TABLE_NAME='shop' THEN
  DELETE FROM ritc.trip_substitution WHERE household_id=NEW.household_id AND shop_id=NEW.shop_id;
  DELETE FROM ritc.trip_picking_permission WHERE household_id=NEW.household_id AND shop_id=NEW.shop_id;
  DELETE FROM ritc.trip_picking_operation WHERE household_id=NEW.household_id AND shop_id=NEW.shop_id;
  DELETE FROM ritc.trip_picking_row WHERE household_id=NEW.household_id AND shop_id=NEW.shop_id;
 ELSIF TG_TABLE_NAME='member' THEN
  UPDATE ritc.trip_substitution SET revision=revision+1,choice=NULL,alternative=NULL,client_key=NULL,fingerprint=NULL
   WHERE household_id=NEW.household_id AND NEW.member_id IN (author_id,shopper_id);
  DELETE FROM ritc.trip_picking_permission WHERE household_id=NEW.household_id AND NEW.member_id IN (recipient_id,shopper_id);
  DELETE FROM ritc.trip_picking_operation WHERE household_id=NEW.household_id AND actor_id=NEW.member_id;
  UPDATE ritc.trip_picking_row SET last_actor=NULL,last_operation=NULL WHERE household_id=NEW.household_id AND last_actor=NEW.member_id;
  UPDATE ritc.trip_picking_row SET claimed_by=NULL WHERE household_id=NEW.household_id AND claimed_by=NEW.member_id;
 ELSIF TG_TABLE_NAME='moderation_block' THEN
  UPDATE ritc.trip_substitution SET revision=revision+1,choice=NULL,alternative=NULL,client_key=NULL,fingerprint=NULL
   WHERE household_id=NEW.household_id AND (author_id,shopper_id) IN ((NEW.viewer_id,NEW.author_id),(NEW.author_id,NEW.viewer_id));
  DELETE FROM ritc.trip_picking_permission WHERE household_id=NEW.household_id
   AND (shopper_id,recipient_id) IN ((NEW.viewer_id,NEW.author_id),(NEW.author_id,NEW.viewer_id));
 ELSIF TG_TABLE_NAME='request' THEN
  UPDATE ritc.trip_substitution SET revision=revision+1,choice=NULL,alternative=NULL,client_key=NULL,fingerprint=NULL
   WHERE household_id=NEW.household_id AND request_id=NEW.request_id;
 ELSIF TG_TABLE_NAME='request_link' THEN
  UPDATE ritc.trip_picking_row SET published_permission=NULL,claimed_by=NULL,last_operation=NULL,revision=revision+1
   WHERE household_id=NEW.household_id AND shop_id=NEW.shop_id AND line_id=NEW.line_id;
 ELSE
  IF NEW.original_item IS DISTINCT FROM OLD.original_item THEN
   DELETE FROM ritc.trip_picking_row WHERE household_id=OLD.household_id AND shop_id=OLD.shop_id AND line_id=OLD.line_id;
  ELSE
   -- The same pack still has its physical picks. A changed target requires review.
   UPDATE ritc.trip_picking_row SET published_permission=NULL,claimed_by=NULL,last_operation=NULL,revision=revision+1
    WHERE household_id=NEW.household_id AND shop_id=NEW.shop_id AND line_id=NEW.line_id;
  END IF;
 END IF;
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION ritc.end_trip_coordination() FROM PUBLIC;
CREATE TRIGGER trip_shop_ends AFTER UPDATE ON ritc.shop FOR EACH ROW
 WHEN(NEW.shopper_id<>OLD.shopper_id OR NEW.authority_epoch<>OLD.authority_epoch OR
   (NEW.phase IN ('placed','closed') AND NEW.phase<>OLD.phase)) EXECUTE FUNCTION ritc.end_trip_coordination();
CREATE TRIGGER trip_actor_ends AFTER UPDATE ON ritc.member FOR EACH ROW
 WHEN(NEW.state<>OLD.state OR NEW.kind<>OLD.kind OR NEW.erased_at IS DISTINCT FROM OLD.erased_at OR (OLD.can_contribute AND NOT NEW.can_contribute))
 EXECUTE FUNCTION ritc.end_trip_coordination();
CREATE TRIGGER trip_block_ends AFTER INSERT ON ritc.moderation_block FOR EACH ROW EXECUTE FUNCTION ritc.end_trip_coordination();
CREATE TRIGGER trip_request_changes AFTER UPDATE ON ritc.request FOR EACH ROW
 WHEN(NEW.original_item IS DISTINCT FROM OLD.original_item OR NEW.own_quantity IS DISTINCT FROM OLD.own_quantity OR
 NEW.route<>OLD.route OR (NEW.status<>OLD.status AND NEW.status IN ('withdrawn','dismissed','handled','deferred')))
 EXECUTE FUNCTION ritc.end_trip_coordination();
CREATE TRIGGER trip_link_changes AFTER INSERT OR UPDATE OF line_id ON ritc.request_link FOR EACH ROW
 EXECUTE FUNCTION ritc.end_trip_coordination();
CREATE TRIGGER trip_pack_changes AFTER UPDATE ON ritc.basket_line FOR EACH ROW
 WHEN(NEW.original_item IS DISTINCT FROM OLD.original_item OR NEW.packs<>OLD.packs)
 EXECUTE FUNCTION ritc.end_trip_coordination();

CREATE FUNCTION ritc.discard_restored_trip_coordination() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 DELETE FROM ritc.trip_picking_permission;
 DELETE FROM ritc.trip_picking_operation;
 DELETE FROM ritc.trip_picking_row;
 DELETE FROM ritc.trip_substitution;
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION ritc.discard_restored_trip_coordination() FROM PUBLIC;
CREATE TRIGGER discard_restored_trip_coordination AFTER INSERT ON ritc.privacy_restore_run
 FOR EACH ROW EXECUTE FUNCTION ritc.discard_restored_trip_coordination();
