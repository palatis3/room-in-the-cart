-- The link from an added request can survive a later draft edit. Only a line
-- actually present in the placed snapshot can receive a purchase observation.
CREATE VIEW ritc.placed_request_link WITH (security_invoker=true) AS
 SELECT l.household_id,l.request_id,l.shop_id,l.line_id,s.placed_revision
 FROM ritc.request_link l
 JOIN ritc.request r USING(household_id,request_id,shop_id)
 JOIN ritc.shop s USING(household_id,shop_id)
 JOIN ritc.shop_snapshot ss ON (ss.household_id,ss.shop_id,ss.revision)=(s.household_id,s.shop_id,s.placed_revision)
 WHERE r.status='added' AND s.phase IN ('placed','closed') AND EXISTS (
  SELECT FROM jsonb_array_elements(ss.snapshot->'lines') line WHERE lower(line->>'lineId')=l.line_id::text
   AND NOT (ss.digest=repeat('0',64) AND line->>'originalItem'='Removed item')
 );
GRANT SELECT ON ritc.placed_request_link TO ritc_app;

CREATE TABLE ritc.request_purchase_review (
 household_id uuid NOT NULL, operation_id uuid NOT NULL, request_id uuid NOT NULL, request_revision integer NOT NULL CHECK(request_revision>1),
 actor_id uuid NOT NULL, shop_id uuid NOT NULL, placed_revision integer NOT NULL,
 outcome text NOT NULL CHECK(outcome IN ('bought','notBought','unknown')),
 PRIMARY KEY(household_id,operation_id), UNIQUE(household_id,request_id,request_revision),
 FOREIGN KEY(household_id,request_id) REFERENCES ritc.request_link ON DELETE CASCADE,
 FOREIGN KEY(household_id,shop_id,placed_revision) REFERENCES ritc.shop_snapshot ON DELETE CASCADE,
 FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member,
 FOREIGN KEY(household_id,operation_id) REFERENCES ritc.operation DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX request_purchase_review_actor ON ritc.request_purchase_review(household_id,actor_id);
CREATE INDEX request_purchase_review_snapshot ON ritc.request_purchase_review(household_id,shop_id,placed_revision);
ALTER TABLE ritc.request_purchase_review ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.request_purchase_review FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON ritc.request_purchase_review TO ritc_app
 USING(household_id::text=(SELECT current_setting('app.household_id',true)))
 WITH CHECK(household_id::text=(SELECT current_setting('app.household_id',true)));
GRANT SELECT,INSERT ON ritc.request_purchase_review TO ritc_app;

-- A redacted review loses its exact-retry receipt. Advance the request head
-- only if this was the current review, so an older answer never resurfaces.
CREATE FUNCTION ritc.erase_request_purchase_receipt() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 DELETE FROM ritc.operation_response WHERE (household_id,operation_id)=(OLD.household_id,OLD.operation_id);
 UPDATE ritc.operation SET payload_digest=repeat('0',64) WHERE (household_id,operation_id)=(OLD.household_id,OLD.operation_id);
 UPDATE ritc.request SET revision=revision+1
 WHERE (household_id,request_id,revision)=(OLD.household_id,OLD.request_id,OLD.request_revision);
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION ritc.erase_request_purchase_receipt() FROM PUBLIC;
CREATE TRIGGER erase_request_purchase_receipt AFTER DELETE ON ritc.request_purchase_review
 FOR EACH ROW EXECUTE FUNCTION ritc.erase_request_purchase_receipt();

CREATE FUNCTION ritc.erase_redacted_purchase_line() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 DELETE FROM ritc.request_purchase_review p
 WHERE (p.household_id,p.shop_id,p.placed_revision)=(NEW.household_id,NEW.shop_id,NEW.revision)
 AND NOT EXISTS(SELECT FROM ritc.placed_request_link l WHERE (l.household_id,l.request_id)=(p.household_id,p.request_id));
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION ritc.erase_redacted_purchase_line() FROM PUBLIC;
CREATE TRIGGER erase_redacted_purchase_line AFTER UPDATE OF snapshot ON ritc.shop_snapshot FOR EACH ROW
 WHEN(OLD.snapshot IS DISTINCT FROM NEW.snapshot) EXECUTE FUNCTION ritc.erase_redacted_purchase_line();

ALTER FUNCTION ritc.privacy_erase_extension(uuid,uuid) RENAME TO privacy_erase_before_request_purchase;
CREATE FUNCTION ritc.privacy_erase_extension(target_household uuid,target_member uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 DELETE FROM ritc.request_purchase_review p WHERE p.household_id=target_household AND p.actor_id=target_member;
 PERFORM ritc.privacy_erase_before_request_purchase(target_household,target_member);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_extension(uuid,uuid) FROM PUBLIC;
