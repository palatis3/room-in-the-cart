-- Household-scoped physical stock. Storing delivery food adds metadata to the
-- existing source; the delivery observation remains its only physical count.
ALTER TABLE ritc.household ADD COLUMN pantry_revision integer NOT NULL DEFAULT 0 CHECK(pantry_revision>=0);
ALTER TABLE ritc.dated_cook_copy ADD COLUMN pantry_revision integer CHECK(pantry_revision>=0);
CREATE TABLE ritc.pantry_lot (
 household_id uuid NOT NULL, lot_id uuid NOT NULL, origin_shop_id uuid NOT NULL, delivery_source_id uuid,
 location text NOT NULL CHECK(location IN ('pantry','freezer')), stored_at timestamptz, use_first_at timestamptz,
 food_name text, exclusion_tags text[], actor_id uuid NOT NULL, operation_id uuid NOT NULL,
 PRIMARY KEY(household_id,lot_id), UNIQUE(household_id,operation_id),
 CHECK((delivery_source_id IS NULL AND lot_id=operation_id AND food_name IS NOT NULL AND exclusion_tags IS NOT NULL)
    OR (delivery_source_id IS NOT NULL AND lot_id=delivery_source_id AND food_name IS NULL AND exclusion_tags IS NULL)),
 FOREIGN KEY(household_id,origin_shop_id) REFERENCES ritc.shop,
 FOREIGN KEY(household_id,origin_shop_id,delivery_source_id) REFERENCES ritc.delivery_source ON DELETE CASCADE,
 FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member,
 FOREIGN KEY(household_id,operation_id) REFERENCES ritc.operation DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX pantry_lot_actor ON ritc.pantry_lot(household_id,actor_id);
-- Each edit is a receipt-backed historical fact. Foreign keys to the sealed meal
-- ensure that removing the reviewed meal also removes dependent matches/claims.
CREATE TABLE ritc.pantry_event (
 household_id uuid NOT NULL, lot_id uuid NOT NULL, shop_id uuid NOT NULL, operation_id uuid NOT NULL, actor_id uuid NOT NULL,
 kind text NOT NULL CHECK(kind IN ('observe','select','match','reserve')), pantry_revision integer NOT NULL,
 occurrence_id uuid, meal_revision integer, ingredient_id uuid, group_id uuid,
 enabled boolean, confirmed_at timestamptz, quantity jsonb,
 PRIMARY KEY(household_id,operation_id), UNIQUE(household_id,pantry_revision),
 CHECK((kind='observe' AND confirmed_at IS NOT NULL AND occurrence_id IS NULL AND enabled IS NULL)
    OR (kind='select' AND enabled IS NOT NULL AND occurrence_id IS NULL AND confirmed_at IS NULL AND quantity IS NULL)
    OR (kind='match' AND enabled IS NOT NULL AND occurrence_id IS NOT NULL AND confirmed_at IS NULL AND quantity IS NULL)
    OR (kind='reserve' AND enabled IS NULL AND occurrence_id IS NOT NULL AND confirmed_at IS NULL)),
 CHECK((occurrence_id IS NULL)=(meal_revision IS NULL) AND (occurrence_id IS NULL)=(ingredient_id IS NULL)),
 CHECK((kind='reserve')=(group_id IS NOT NULL)),
 FOREIGN KEY(household_id,lot_id) REFERENCES ritc.pantry_lot ON DELETE CASCADE,
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,
 FOREIGN KEY(household_id,shop_id,occurrence_id,meal_revision) REFERENCES ritc.shared_meal_revision ON DELETE CASCADE,
 FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member,
 FOREIGN KEY(household_id,operation_id) REFERENCES ritc.operation DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX pantry_event_head ON ritc.pantry_event(household_id,lot_id,kind,shop_id,occurrence_id,meal_revision,ingredient_id,group_id,pantry_revision DESC);
CREATE INDEX pantry_event_actor ON ritc.pantry_event(household_id,actor_id);
CREATE INDEX pantry_event_meal ON ritc.pantry_event(household_id,shop_id,occurrence_id,meal_revision);
-- Historical provenance used only for privacy erasure. The household reader
-- never receives another shop, meal, member, or recipient identifier.
CREATE TABLE ritc.cook_copy_pantry_scope(
 household_id uuid NOT NULL,copy_id uuid NOT NULL,shop_id uuid NOT NULL,
 PRIMARY KEY(household_id,copy_id,shop_id),
 FOREIGN KEY(household_id,copy_id) REFERENCES ritc.dated_cook_copy ON DELETE CASCADE,
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop
);
CREATE INDEX cook_copy_pantry_shop ON ritc.cook_copy_pantry_scope(household_id,shop_id);
CREATE TABLE ritc.cook_copy_pantry_actor(
 household_id uuid NOT NULL,copy_id uuid NOT NULL,member_id uuid NOT NULL,
 PRIMARY KEY(household_id,copy_id,member_id),
 FOREIGN KEY(household_id,copy_id) REFERENCES ritc.dated_cook_copy ON DELETE CASCADE,
 FOREIGN KEY(household_id,member_id) REFERENCES ritc.member
);
CREATE INDEX cook_copy_pantry_member ON ritc.cook_copy_pantry_actor(household_id,member_id);
DO $$
DECLARE relation text;
BEGIN
 FOREACH relation IN ARRAY ARRAY['pantry_lot','pantry_event','cook_copy_pantry_scope','cook_copy_pantry_actor'] LOOP
  EXECUTE format('ALTER TABLE ritc.%I ENABLE ROW LEVEL SECURITY',relation);
  EXECUTE format('ALTER TABLE ritc.%I FORCE ROW LEVEL SECURITY',relation);
  EXECUTE format('CREATE POLICY tenant_scope ON ritc.%I TO ritc_app USING(household_id::text=(SELECT current_setting(''app.household_id'',true))) WITH CHECK(household_id::text=(SELECT current_setting(''app.household_id'',true)))',relation);
 END LOOP;
END $$;
GRANT SELECT,INSERT ON ritc.pantry_lot,ritc.pantry_event,ritc.cook_copy_pantry_scope,ritc.cook_copy_pantry_actor TO ritc_app;
GRANT UPDATE(pantry_revision) ON ritc.household TO ritc_app;

CREATE FUNCTION ritc.advance_joint_supply() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 UPDATE ritc.household SET pantry_revision=pantry_revision+1 WHERE household_id=NEW.household_id;
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION ritc.advance_joint_supply() FROM PUBLIC;
CREATE TRIGGER advance_joint_supply AFTER UPDATE OF supply_revision ON ritc.shop FOR EACH ROW
 WHEN(NEW.supply_revision<>OLD.supply_revision) EXECUTE FUNCTION ritc.advance_joint_supply();

CREATE FUNCTION ritc.erase_redacted_joint_copies() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 DELETE FROM ritc.dated_cook_copy c WHERE c.household_id=NEW.household_id AND EXISTS(
   SELECT FROM ritc.cook_copy_pantry_scope p JOIN ritc.dated_cook_copy earlier USING(household_id,copy_id)
   WHERE p.household_id=NEW.household_id AND p.shop_id=NEW.shop_id AND
     (earlier.shop_id,earlier.occurrence_id)=(c.shop_id,c.occurrence_id) AND earlier.version<=c.version);
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION ritc.erase_redacted_joint_copies() FROM PUBLIC;
CREATE TRIGGER erase_joint_copy_sources AFTER UPDATE OF snapshot ON ritc.shop_snapshot FOR EACH ROW
 WHEN(OLD.snapshot IS DISTINCT FROM NEW.snapshot) EXECUTE FUNCTION ritc.erase_redacted_joint_copies();

ALTER FUNCTION ritc.privacy_erase_extension(uuid,uuid) RENAME TO privacy_erase_before_household_pantry;
CREATE FUNCTION ritc.privacy_erase_extension(target_household uuid,target_member uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 -- Joint text may incorporate another shop's private commitments or delivery.
 -- Erase joint copies that could contain this member's data and dependent sends.
 DELETE FROM ritc.dated_cook_copy c WHERE c.household_id=target_household AND EXISTS(
   SELECT FROM ritc.cook_copy_pantry_actor p JOIN ritc.dated_cook_copy earlier USING(household_id,copy_id)
   WHERE p.household_id=target_household AND p.member_id=target_member AND
     (earlier.shop_id,earlier.occurrence_id)=(c.shop_id,c.occurrence_id) AND earlier.version<=c.version);
 -- Do not restore earlier stock, selections, or promises by erasing a later
 -- correction. Remove a decision's complete history and its dependent reviews.
 DELETE FROM ritc.pantry_event e USING ritc.pantry_event a WHERE a.household_id=target_household AND a.actor_id=target_member
 AND (e.household_id,e.lot_id)=(a.household_id,a.lot_id) AND (
   (a.kind='observe' AND e.kind='observe') OR
   (e.shop_id=a.shop_id AND (a.kind='select' AND e.kind IN ('select','match','reserve') OR
     e.occurrence_id=a.occurrence_id AND e.meal_revision=a.meal_revision AND e.ingredient_id=a.ingredient_id AND
     (a.kind='match' AND e.kind IN ('match','reserve') OR a.kind='reserve' AND e.kind='reserve' AND e.group_id=a.group_id))));
 DELETE FROM ritc.pantry_lot WHERE household_id=target_household AND actor_id=target_member;
 UPDATE ritc.household SET pantry_revision=pantry_revision+1 WHERE household_id=target_household;
 PERFORM ritc.privacy_erase_before_household_pantry(target_household,target_member);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_extension(uuid,uuid) FROM PUBLIC;
