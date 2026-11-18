-- Legacy event and lot identifiers remain valid. New operations may append several
-- stock facts under one household revision, retaining one receipt for the batch.
CREATE TABLE ritc.pantry_batch (
 household_id uuid NOT NULL, operation_id uuid NOT NULL, pantry_revision integer NOT NULL,
 PRIMARY KEY(household_id,operation_id), UNIQUE(household_id,pantry_revision),
 UNIQUE(household_id,operation_id,pantry_revision),
 FOREIGN KEY(household_id,operation_id) REFERENCES ritc.operation DEFERRABLE INITIALLY DEFERRED
);
INSERT INTO ritc.pantry_batch SELECT household_id,operation_id,pantry_revision FROM ritc.pantry_event;
INSERT INTO ritc.pantry_batch SELECT l.household_id,l.operation_id,(r.response->>'pantryRevision')::integer
 FROM ritc.pantry_lot l JOIN ritc.operation_response r USING(household_id,operation_id)
 WHERE r.response->>'pantryRevision' IS NOT NULL ON CONFLICT DO NOTHING;

ALTER TABLE ritc.pantry_event ADD COLUMN event_id uuid;
UPDATE ritc.pantry_event SET event_id=operation_id;
ALTER TABLE ritc.pantry_event ALTER COLUMN event_id SET NOT NULL,
 DROP CONSTRAINT pantry_event_household_id_lot_id_predecessor_observation_i_fkey,
 DROP CONSTRAINT pantry_event_household_id_lot_id_operation_id_key,
 DROP CONSTRAINT pantry_event_pkey, DROP CONSTRAINT pantry_event_household_id_pantry_revision_key,
 ADD PRIMARY KEY(household_id,event_id), ADD UNIQUE(household_id,lot_id,event_id),
 ADD FOREIGN KEY(household_id,lot_id,predecessor_observation_id)
   REFERENCES ritc.pantry_event(household_id,lot_id,event_id) ON DELETE CASCADE,
 ADD FOREIGN KEY(household_id,operation_id,pantry_revision)
   REFERENCES ritc.pantry_batch(household_id,operation_id,pantry_revision),
 ADD COLUMN delivery_usable_id uuid;
CREATE UNIQUE INDEX pantry_observation_batch_lot ON ritc.pantry_event(household_id,operation_id,lot_id) WHERE kind='observe';

CREATE FUNCTION ritc.bind_pantry_batch() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE revision integer;
BEGIN
 IF TG_TABLE_NAME='pantry_lot' THEN
   SELECT pantry_revision+1 INTO revision FROM ritc.household WHERE household_id=NEW.household_id;
 ELSE
   NEW.event_id:=COALESCE(NEW.event_id,NEW.operation_id);
   revision:=NEW.pantry_revision;
 END IF;
 INSERT INTO ritc.pantry_batch(household_id,operation_id,pantry_revision)
 VALUES(NEW.household_id,NEW.operation_id,revision) ON CONFLICT(household_id,operation_id) DO NOTHING;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ritc.bind_pantry_batch() FROM PUBLIC;
CREATE TRIGGER bind_pantry_batch BEFORE INSERT ON ritc.pantry_event FOR EACH ROW EXECUTE FUNCTION ritc.bind_pantry_batch();
CREATE TRIGGER bind_pantry_batch BEFORE INSERT ON ritc.pantry_lot FOR EACH ROW EXECUTE FUNCTION ritc.bind_pantry_batch();

CREATE TABLE ritc.shared_cook (
 household_id uuid NOT NULL, operation_id uuid NOT NULL, shop_id uuid NOT NULL, occurrence_id uuid NOT NULL,
 meal_revision integer NOT NULL, recipe_revision_id uuid NOT NULL, actor_id uuid NOT NULL,
 servings integer NOT NULL CHECK(servings BETWEEN 1 AND 1000), undone_by uuid,
 PRIMARY KEY(household_id,operation_id),
 FOREIGN KEY(household_id,shop_id,occurrence_id,meal_revision) REFERENCES ritc.shared_meal_revision ON DELETE CASCADE,
 FOREIGN KEY(household_id,operation_id) REFERENCES ritc.pantry_batch,
 FOREIGN KEY(household_id,undone_by) REFERENCES ritc.pantry_batch,
 FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member
);
CREATE UNIQUE INDEX shared_cook_current ON ritc.shared_cook(household_id,shop_id,occurrence_id) WHERE undone_by IS NULL;

ALTER TABLE ritc.pantry_lot ADD COLUMN cook_output boolean NOT NULL DEFAULT false,
 DROP CONSTRAINT pantry_lot_household_id_operation_id_key, DROP CONSTRAINT pantry_lot_check,
 DROP CONSTRAINT pantry_lot_check1,
 ADD CHECK ((delivery_source_id IS NULL AND (lot_id=operation_id OR cook_output) AND food_name IS NOT NULL AND exclusion_tags IS NOT NULL)
   OR (delivery_source_id IS NOT NULL AND lot_id=delivery_source_id AND NOT cook_output AND food_name IS NULL AND exclusion_tags IS NULL)),
 ADD CHECK (NOT cook_output OR origin_shop_id IS NOT NULL),
 ADD CHECK (location IN ('pantry','freezer') OR (location='fridge' AND (origin_shop_id IS NULL OR cook_output)));
CREATE INDEX pantry_lot_receipt ON ritc.pantry_lot(household_id,operation_id);

-- One stable event per reviewed ingredient split, including explicit non-use
-- and untracked use. Physical balance changes are separate canonical observations.
CREATE TABLE ritc.cook_use (
 household_id uuid NOT NULL, cook_id uuid NOT NULL, row_id uuid NOT NULL, need_id uuid NOT NULL,
 kind text NOT NULL CHECK(kind IN ('known','unknown','notUsed')), lot_id uuid, quantity jsonb,
 PRIMARY KEY(household_id,row_id),
 CHECK ((kind='known')=(quantity IS NOT NULL) AND (kind<>'known' OR lot_id IS NOT NULL) AND (kind<>'notUsed' OR lot_id IS NULL)),
 FOREIGN KEY(household_id,cook_id) REFERENCES ritc.shared_cook ON DELETE CASCADE,
 FOREIGN KEY(household_id,lot_id) REFERENCES ritc.pantry_lot ON DELETE CASCADE
);
CREATE INDEX cook_use_meal ON ritc.cook_use(household_id,cook_id);

CREATE TABLE ritc.cook_stock_change (
 household_id uuid NOT NULL, cook_id uuid NOT NULL, operation_id uuid NOT NULL, lot_id uuid NOT NULL,
 event_id uuid NOT NULL, before_quantity jsonb, is_output boolean NOT NULL,
 PRIMARY KEY(household_id,operation_id,lot_id),
 FOREIGN KEY(household_id,cook_id) REFERENCES ritc.shared_cook ON DELETE CASCADE,
 FOREIGN KEY(household_id,lot_id,event_id) REFERENCES ritc.pantry_event(household_id,lot_id,event_id) ON DELETE CASCADE
);
CREATE INDEX cook_stock_history ON ritc.cook_stock_change(household_id,cook_id);
-- A named promise is fulfilled only for the amount actually deducted. Physical
-- receipt rows stay immutable; the current projection subtracts active fulfillments.
CREATE TABLE ritc.cook_fulfillment (
 household_id uuid NOT NULL, cook_id uuid NOT NULL, reservation_id uuid NOT NULL, quantity jsonb NOT NULL, operation_id uuid NOT NULL,
 PRIMARY KEY(household_id,operation_id,reservation_id),
 FOREIGN KEY(household_id,operation_id) REFERENCES ritc.pantry_batch,
 FOREIGN KEY(household_id,cook_id) REFERENCES ritc.shared_cook ON DELETE CASCADE
);
CREATE TABLE ritc.cook_resolution (
 household_id uuid NOT NULL,row_id uuid NOT NULL,operation_id uuid NOT NULL,lot_id uuid NOT NULL,
 quantity jsonb NOT NULL, included_in_count boolean NOT NULL,
 PRIMARY KEY(household_id,row_id), UNIQUE(household_id,operation_id),
 FOREIGN KEY(household_id,row_id) REFERENCES ritc.cook_use ON DELETE CASCADE,
 FOREIGN KEY(household_id,operation_id) REFERENCES ritc.pantry_batch,
 FOREIGN KEY(household_id,lot_id) REFERENCES ritc.pantry_lot ON DELETE CASCADE
);
SET CONSTRAINTS ALL IMMEDIATE;
DO $$
DECLARE relation text;
BEGIN
 FOREACH relation IN ARRAY ARRAY['pantry_batch','shared_cook','cook_use','cook_stock_change','cook_fulfillment','cook_resolution'] LOOP
  EXECUTE format('ALTER TABLE ritc.%I ENABLE ROW LEVEL SECURITY',relation);
  EXECUTE format('ALTER TABLE ritc.%I FORCE ROW LEVEL SECURITY',relation);
  EXECUTE format('CREATE POLICY tenant_scope ON ritc.%I TO ritc_app USING(household_id::text=(SELECT current_setting(''app.household_id'',true))) WITH CHECK(household_id::text=(SELECT current_setting(''app.household_id'',true)))',relation);
  EXECUTE format('GRANT SELECT,INSERT ON ritc.%I TO ritc_app',relation);
 END LOOP;
END $$;
GRANT UPDATE(undone_by) ON ritc.shared_cook TO ritc_app;

-- Derived outputs and receipts follow their reviewed meal and physical sources.
ALTER TABLE ritc.pantry_lot ADD COLUMN cook_id uuid GENERATED ALWAYS AS
 (CASE WHEN cook_output THEN operation_id END) STORED,
 ADD FOREIGN KEY(household_id,cook_id) REFERENCES ritc.shared_cook ON DELETE CASCADE;
CREATE INDEX pantry_output_meal ON ritc.pantry_lot(household_id,cook_id) WHERE cook_id IS NOT NULL;
CREATE FUNCTION ritc.forget_cook_lot() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 DELETE FROM ritc.shared_cook c USING ritc.cook_use u WHERE (u.household_id,u.lot_id)=(OLD.household_id,OLD.lot_id)
 AND (c.household_id,c.operation_id)=(u.household_id,u.cook_id);
 DELETE FROM ritc.shared_cook c USING ritc.cook_resolution x,ritc.cook_use u WHERE (x.household_id,x.lot_id)=(OLD.household_id,OLD.lot_id)
 AND (x.household_id,x.row_id)=(u.household_id,u.row_id) AND (c.household_id,c.operation_id)=(u.household_id,u.cook_id);
 RETURN OLD;
END $$;
REVOKE ALL ON FUNCTION ritc.forget_cook_lot() FROM PUBLIC;
CREATE TRIGGER forget_cook_lot BEFORE DELETE ON ritc.pantry_lot FOR EACH ROW EXECUTE FUNCTION ritc.forget_cook_lot();
CREATE FUNCTION ritc.forget_cook_recipe() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 DELETE FROM ritc.shared_cook WHERE (household_id,shop_id,occurrence_id)=(NEW.household_id,NEW.shop_id,NEW.occurrence_id);
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION ritc.forget_cook_recipe() FROM PUBLIC;
CREATE TRIGGER forget_cook_recipe AFTER UPDATE OF meal ON ritc.shared_meal_revision FOR EACH ROW
 WHEN (OLD.meal IS DISTINCT FROM NEW.meal) EXECUTE FUNCTION ritc.forget_cook_recipe();
CREATE TRIGGER forget_cook_replacement AFTER UPDATE OF current_meal ON ritc.meal_recovery_revision FOR EACH ROW
 WHEN (OLD.current_meal IS DISTINCT FROM NEW.current_meal) EXECUTE FUNCTION ritc.forget_cook_recipe();

ALTER FUNCTION ritc.privacy_erase_extension(uuid,uuid) RENAME TO privacy_erase_before_cook_completion;
CREATE FUNCTION ritc.privacy_erase_extension(target_household uuid,target_member uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 -- When an erased cook contributed a derived physical balance, forgetting its
 -- observation must not restore the previously received amount as available.
 DELETE FROM ritc.delivery_source d USING ritc.pantry_lot l,ritc.pantry_event e WHERE e.household_id=target_household
   AND e.actor_id=target_member AND e.delivery_usable_id IS NOT NULL AND (e.household_id,e.lot_id)=(l.household_id,l.lot_id)
   AND (d.household_id,d.shop_id,d.source_id)=(l.household_id,l.origin_shop_id,l.delivery_source_id);
 DELETE FROM ritc.shared_cook c WHERE c.household_id=target_household AND (c.actor_id=target_member OR EXISTS(
   SELECT 1 FROM ritc.cook_stock_change s JOIN ritc.pantry_event e USING(household_id,lot_id)
   WHERE (s.household_id,s.cook_id)=(c.household_id,c.operation_id) AND e.actor_id=target_member));
 PERFORM ritc.privacy_erase_before_cook_completion(target_household,target_member);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_extension(uuid,uuid) FROM PUBLIC;

-- Physical and reservation changes in former shops share the household clock.
-- Prior rows predate the first cook receipt and keep the zero watermark.
ALTER TABLE ritc.delivery_observation ADD COLUMN household_revision integer NOT NULL DEFAULT 0;
ALTER TABLE ritc.delivery_reservation ADD COLUMN household_revision integer NOT NULL DEFAULT 0;
ALTER TABLE ritc.delivery_ingredient_review ADD COLUMN household_revision integer NOT NULL DEFAULT 0;
CREATE FUNCTION ritc.stamp_joint_change() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 SELECT pantry_revision+1 INTO NEW.household_revision FROM ritc.household WHERE household_id=NEW.household_id;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ritc.stamp_joint_change() FROM PUBLIC;
CREATE TRIGGER stamp_joint_change BEFORE INSERT ON ritc.delivery_observation FOR EACH ROW EXECUTE FUNCTION ritc.stamp_joint_change();
CREATE TRIGGER stamp_joint_change BEFORE INSERT ON ritc.delivery_reservation FOR EACH ROW EXECUTE FUNCTION ritc.stamp_joint_change();
CREATE TRIGGER stamp_joint_change BEFORE INSERT ON ritc.delivery_ingredient_review FOR EACH ROW EXECUTE FUNCTION ritc.stamp_joint_change();
CREATE INDEX cook_fulfilled_head ON ritc.cook_fulfillment(household_id,reservation_id);
