-- Retailer evidence does not rewrite checkout or imply any physical/financial receipt.
ALTER TABLE ritc.shop ADD COLUMN confirmed_order_erased boolean NOT NULL DEFAULT false;
CREATE TABLE ritc.order_amendment (
 household_id uuid NOT NULL,shop_id uuid NOT NULL,amendment_id uuid NOT NULL,placed_revision integer NOT NULL,
 predecessor_id uuid,shop_revision integer NOT NULL CHECK(shop_revision>0),authority_epoch integer NOT NULL CHECK(authority_epoch>0),
 retailer_reference text NOT NULL CHECK(length(retailer_reference) BETWEEN 1 AND 240),confirmed_at timestamptz NOT NULL,
 recorded_at timestamptz NOT NULL,actor_id uuid NOT NULL,operation_id uuid NOT NULL,lines jsonb NOT NULL,
 PRIMARY KEY(household_id,shop_id,amendment_id),UNIQUE(household_id,shop_id,shop_revision),UNIQUE(household_id,operation_id),
 CHECK(jsonb_typeof(lines)='array' AND jsonb_array_length(lines)<=200),CHECK(confirmed_at<=recorded_at),
 FOREIGN KEY(household_id,shop_id,placed_revision) REFERENCES ritc.shop_snapshot,
 FOREIGN KEY(household_id,shop_id,predecessor_id) REFERENCES ritc.order_amendment DEFERRABLE INITIALLY DEFERRED,
 FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member,
 FOREIGN KEY(household_id,operation_id) REFERENCES ritc.operation DEFERRABLE INITIALLY DEFERRED
);
CREATE UNIQUE INDEX order_amendment_successor ON ritc.order_amendment(household_id,shop_id,predecessor_id) NULLS NOT DISTINCT;
CREATE INDEX order_amendment_actor ON ritc.order_amendment(household_id,actor_id);
ALTER TABLE ritc.order_amendment ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.order_amendment FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON ritc.order_amendment TO ritc_app
 USING(household_id::text=(SELECT current_setting('app.household_id',true)))
 WITH CHECK(household_id::text=(SELECT current_setting('app.household_id',true)));
GRANT SELECT,INSERT ON ritc.order_amendment TO ritc_app;
CREATE TRIGGER order_amendment_immutable BEFORE UPDATE OR DELETE ON ritc.order_amendment FOR EACH ROW EXECUTE FUNCTION ritc.immutable_row();

-- Full-state successors repeat earlier source facts. Erase the dependent chain
-- as one unit and retain a content-free fence, never roll back to an older order.
CREATE FUNCTION ritc.erase_confirmed_order(target_household uuid,target_shop uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NOT ritc.privacy_erasure_authorized() THEN RAISE EXCEPTION 'erasure authority required'; END IF;
 IF NOT EXISTS(SELECT 1 FROM ritc.order_amendment WHERE household_id=target_household AND shop_id=target_shop) THEN RETURN; END IF;
 DELETE FROM ritc.operation_response r USING ritc.order_amendment a
 WHERE (r.household_id,r.operation_id)=(a.household_id,a.operation_id) AND a.household_id=target_household AND a.shop_id=target_shop;
 UPDATE ritc.operation o SET payload_digest=repeat('0',64) FROM ritc.order_amendment a
 WHERE (o.household_id,o.operation_id)=(a.household_id,a.operation_id) AND a.household_id=target_household AND a.shop_id=target_shop;
 -- Dated wording and recovery publications may contain facts copied from these
 -- physical sources, including another shop using their pantry lot.
 DELETE FROM ritc.dated_cook_copy c WHERE c.household_id=target_household AND
   (c.shop_id=target_shop OR EXISTS(SELECT 1 FROM ritc.cook_copy_pantry_scope p JOIN ritc.dated_cook_copy earlier USING(household_id,copy_id)
     WHERE p.household_id=c.household_id AND p.shop_id=target_shop
     AND (earlier.shop_id,earlier.occurrence_id)=(c.shop_id,c.occurrence_id) AND earlier.version<=c.version));
 PERFORM ritc.redact_meal_recoveries(target_household,NULL,target_shop);
 -- This is privacy erasure, never cancellation. Unaffected original physical sources remain.
 DELETE FROM ritc.delivery_source d WHERE d.household_id=target_household AND d.shop_id=target_shop AND NOT EXISTS(
   SELECT 1 FROM ritc.shop_snapshot ss,jsonb_array_elements(ss.snapshot->'lines') line
   WHERE (ss.household_id,ss.shop_id,ss.revision)=(d.household_id,d.shop_id,d.placed_revision)
   AND lower(line->>'lineId')=d.line_id::text AND NOT(ss.digest=repeat('0',64) AND line->>'originalItem'='Removed item'));
 DELETE FROM ritc.order_amendment WHERE household_id=target_household AND shop_id=target_shop;
 UPDATE ritc.shop SET confirmed_order_erased=true,revision=revision+1,supply_revision=supply_revision+1
 WHERE household_id=target_household AND shop_id=target_shop;
END $$;
REVOKE ALL ON FUNCTION ritc.erase_confirmed_order(uuid,uuid) FROM PUBLIC;

CREATE FUNCTION ritc.erase_confirmed_order_from_snapshot() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NEW.digest=repeat('0',64) THEN PERFORM ritc.erase_confirmed_order(NEW.household_id,NEW.shop_id); END IF;
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION ritc.erase_confirmed_order_from_snapshot() FROM PUBLIC;
CREATE TRIGGER erase_confirmed_order_from_snapshot AFTER UPDATE OF snapshot ON ritc.shop_snapshot FOR EACH ROW
 WHEN(OLD.snapshot IS DISTINCT FROM NEW.snapshot) EXECUTE FUNCTION ritc.erase_confirmed_order_from_snapshot();

ALTER FUNCTION ritc.privacy_erase_extension(uuid,uuid) RENAME TO privacy_erase_before_order_amendment;
CREATE FUNCTION ritc.privacy_erase_extension(target_household uuid,target_member uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE target record;
BEGIN
 FOR target IN SELECT DISTINCT shop_id FROM ritc.order_amendment WHERE household_id=target_household AND actor_id=target_member LOOP
   PERFORM ritc.erase_confirmed_order(target_household,target.shop_id);
 END LOOP;
 PERFORM ritc.privacy_erase_before_order_amendment(target_household,target_member);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_extension(uuid,uuid) FROM PUBLIC;
