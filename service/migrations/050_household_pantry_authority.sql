-- The service locks the household before checking the member, device, epoch,
-- replay window and stock revision. These fields follow the existing member RLS.
ALTER TABLE ritc.member
  ADD COLUMN pantry_editor boolean NOT NULL DEFAULT false,
  ADD COLUMN pantry_grant_epoch integer NOT NULL DEFAULT 0 CHECK (pantry_grant_epoch >= 0),
  ADD CHECK (NOT pantry_editor OR (kind='adult' AND state='active' AND NOT organizer));
GRANT UPDATE(pantry_editor) ON ritc.member TO ritc_app;

CREATE FUNCTION ritc.advance_pantry_grant() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  IF NEW.state <> 'active' OR NEW.organizer IS DISTINCT FROM OLD.organizer THEN
    NEW.pantry_editor := false;
  END IF;
  IF (NEW.state,NEW.organizer,NEW.pantry_editor) IS DISTINCT FROM (OLD.state,OLD.organizer,OLD.pantry_editor) THEN
    NEW.pantry_grant_epoch := OLD.pantry_grant_epoch + 1;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ritc.advance_pantry_grant() FROM PUBLIC;
CREATE TRIGGER member_pantry_epoch BEFORE UPDATE OF organizer,state,pantry_editor ON ritc.member
  FOR EACH ROW EXECUTE FUNCTION ritc.advance_pantry_grant();

ALTER TABLE ritc.operation ALTER COLUMN shop_id DROP NOT NULL,
  ADD COLUMN authority_scope text NOT NULL DEFAULT 'shop',
  ADD COLUMN pantry_grant_epoch integer CHECK (pantry_grant_epoch >= 0),
  DROP CONSTRAINT operation_response_scope_check,
  ADD CHECK ((authority_scope='shop' AND shop_id IS NOT NULL AND response_scope IN ('own','shopper','organizer','reporter'))
          OR (authority_scope='household_pantry' AND shop_id IS NULL AND response_scope='pantry' AND pantry_grant_epoch IS NOT NULL)),
  ADD UNIQUE(household_id, operation_id, authority_scope);

ALTER TABLE ritc.pantry_lot ALTER COLUMN origin_shop_id DROP NOT NULL,
  DROP CONSTRAINT pantry_lot_location_check,
  ADD CHECK (location IN ('pantry','freezer') OR (origin_shop_id IS NULL AND location='fridge')),
  ADD CHECK (origin_shop_id IS NOT NULL OR delivery_source_id IS NULL),
  ADD COLUMN authority_scope text GENERATED ALWAYS AS
    (CASE WHEN origin_shop_id IS NULL THEN 'household_pantry' ELSE 'shop' END) STORED,
  ADD FOREIGN KEY(household_id,operation_id,authority_scope) REFERENCES ritc.operation(household_id,operation_id,authority_scope) DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE ritc.pantry_event ALTER COLUMN shop_id DROP NOT NULL,
  ADD CHECK (shop_id IS NOT NULL OR (kind='observe' AND lot_id=operation_id)),
  ADD COLUMN authority_scope text GENERATED ALWAYS AS
    (CASE WHEN shop_id IS NULL THEN 'household_pantry' ELSE 'shop' END) STORED,
  ADD FOREIGN KEY(household_id,operation_id,authority_scope) REFERENCES ritc.operation(household_id,operation_id,authority_scope) DEFERRABLE INITIALLY DEFERRED;

-- A queued legacy shop command carries a pantry revision and no grant epoch.
-- Invalidate those reviews whenever standalone access changes.
CREATE FUNCTION ritc.invalidate_pantry_grant_reviews() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  UPDATE ritc.household SET pantry_revision=pantry_revision+1 WHERE household_id=NEW.household_id;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION ritc.invalidate_pantry_grant_reviews() FROM PUBLIC;
CREATE TRIGGER invalidate_member_pantry_reviews AFTER UPDATE ON ritc.member FOR EACH ROW
  WHEN (NEW.pantry_grant_epoch <> OLD.pantry_grant_epoch) EXECUTE FUNCTION ritc.invalidate_pantry_grant_reviews();
