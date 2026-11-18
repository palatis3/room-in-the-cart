-- Each selected line has its own physical identity. All new observations share
-- the batch operation and revision introduced by 054.
ALTER TABLE ritc.pantry_lot ADD COLUMN receipt_origin boolean NOT NULL DEFAULT false,
 DROP CONSTRAINT pantry_lot_check,
 ADD CHECK ((delivery_source_id IS NULL AND (lot_id=operation_id OR cook_output OR receipt_origin)
             AND food_name IS NOT NULL AND exclusion_tags IS NOT NULL)
    OR (delivery_source_id IS NOT NULL AND lot_id=delivery_source_id AND NOT cook_output AND NOT receipt_origin
             AND food_name IS NULL AND exclusion_tags IS NULL)),
 ADD CHECK (NOT receipt_origin OR (origin_shop_id IS NULL AND NOT cook_output AND lot_id<>operation_id));
ALTER TABLE ritc.pantry_event DROP CONSTRAINT pantry_event_household_observation,
 ADD CONSTRAINT pantry_event_household_observation CHECK (
   (shop_id IS NOT NULL AND predecessor_observation_id IS NULL) OR
   (shop_id IS NULL AND kind='observe' AND (
       (lot_id=event_id AND predecessor_observation_id IS NULL) OR
       (lot_id<>event_id AND predecessor_observation_id IS NOT NULL AND predecessor_observation_id<>event_id))));

-- Keys carry no printed content. Keeping them prevents an erased source from
-- being reimported under a fresh client operation or its alternate image key.
CREATE TABLE ritc.receipt_source_key (
 household_id uuid NOT NULL REFERENCES ritc.household, source_id uuid NOT NULL, receipt_id uuid NOT NULL,
 PRIMARY KEY(household_id,source_id)
);
CREATE TABLE ritc.retired_receipt_line (
 household_id uuid NOT NULL REFERENCES ritc.household, receipt_id uuid NOT NULL, ordinal integer NOT NULL,
 PRIMARY KEY(household_id,receipt_id,ordinal)
);
CREATE TABLE ritc.household_receipt_line (
 household_id uuid NOT NULL, receipt_id uuid NOT NULL, ordinal integer NOT NULL CHECK(ordinal BETWEEN 0 AND 3999),
 lot_id uuid NOT NULL, actor_id uuid NOT NULL, operation_id uuid NOT NULL, evidence jsonb NOT NULL,
 PRIMARY KEY(household_id,receipt_id,ordinal), UNIQUE(household_id,lot_id),
 FOREIGN KEY(household_id,lot_id) REFERENCES ritc.pantry_lot ON DELETE CASCADE,
 FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member,
 FOREIGN KEY(household_id,operation_id) REFERENCES ritc.operation DEFERRABLE INITIALLY DEFERRED,
 CHECK(jsonb_typeof(evidence)='object' AND octet_length(evidence::text)<=16384)
);
CREATE INDEX household_receipt_actor ON ritc.household_receipt_line(household_id,actor_id);
CREATE TABLE ritc.receipt_submission_line (
 household_id uuid NOT NULL, operation_id uuid NOT NULL, receipt_id uuid NOT NULL, ordinal integer NOT NULL,
 PRIMARY KEY(household_id,receipt_id,ordinal,operation_id),
 FOREIGN KEY(household_id,receipt_id,ordinal) REFERENCES ritc.household_receipt_line ON DELETE CASCADE,
 FOREIGN KEY(household_id,operation_id) REFERENCES ritc.operation ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX receipt_submission_operation ON ritc.receipt_submission_line(household_id,operation_id);
DO $$
DECLARE relation text;
BEGIN
 FOREACH relation IN ARRAY ARRAY['receipt_source_key','retired_receipt_line','household_receipt_line','receipt_submission_line'] LOOP
  EXECUTE format('ALTER TABLE ritc.%I ENABLE ROW LEVEL SECURITY',relation);
  EXECUTE format('ALTER TABLE ritc.%I FORCE ROW LEVEL SECURITY',relation);
  EXECUTE format('CREATE POLICY tenant_scope ON ritc.%I TO ritc_app USING(household_id::text=(SELECT current_setting(''app.household_id'',true))) WITH CHECK(household_id::text=(SELECT current_setting(''app.household_id'',true)))',relation);
  EXECUTE format('GRANT SELECT ON ritc.%I TO ritc_app',relation);
 END LOOP;
END $$;
GRANT INSERT ON ritc.receipt_source_key,ritc.household_receipt_line,ritc.receipt_submission_line TO ritc_app;

CREATE FUNCTION ritc.retire_receipt_line() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 INSERT INTO ritc.retired_receipt_line VALUES(OLD.household_id,OLD.receipt_id,OLD.ordinal) ON CONFLICT DO NOTHING;
 DELETE FROM ritc.operation_response r USING ritc.receipt_submission_line s
 WHERE (r.household_id,r.operation_id)=(s.household_id,s.operation_id)
 AND (s.household_id,s.receipt_id,s.ordinal)=(OLD.household_id,OLD.receipt_id,OLD.ordinal);
 RETURN OLD;
END $$;
REVOKE ALL ON FUNCTION ritc.retire_receipt_line() FROM PUBLIC;
CREATE TRIGGER retire_receipt_line BEFORE DELETE ON ritc.household_receipt_line FOR EACH ROW EXECUTE FUNCTION ritc.retire_receipt_line();
ALTER FUNCTION ritc.privacy_erase_extension(uuid,uuid) RENAME TO privacy_erase_before_household_receipts;
CREATE FUNCTION ritc.privacy_erase_extension(target_household uuid,target_member uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 DELETE FROM ritc.household_receipt_line WHERE household_id=target_household AND actor_id=target_member;
 PERFORM ritc.privacy_erase_before_household_receipts(target_household,target_member);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_extension(uuid,uuid) FROM PUBLIC;
