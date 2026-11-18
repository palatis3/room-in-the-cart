-- A bought observation remains separate from an explicitly reported buyer.
CREATE TABLE ritc.request_purchase_buyer (
 household_id uuid NOT NULL, operation_id uuid NOT NULL, buyer_id uuid NOT NULL,
 PRIMARY KEY (household_id,operation_id),
 FOREIGN KEY (household_id,operation_id) REFERENCES ritc.request_purchase_review ON DELETE CASCADE,
 FOREIGN KEY (household_id,buyer_id) REFERENCES ritc.member
);
CREATE INDEX request_purchase_buyer_member ON ritc.request_purchase_buyer(household_id,buyer_id);
ALTER TABLE ritc.request_purchase_buyer ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.request_purchase_buyer FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON ritc.request_purchase_buyer TO ritc_app
 USING(household_id::text=(SELECT current_setting('app.household_id',true)))
 WITH CHECK(household_id::text=(SELECT current_setting('app.household_id',true)));
GRANT SELECT,INSERT ON ritc.request_purchase_buyer TO ritc_app;

ALTER FUNCTION ritc.privacy_erase_extension(uuid,uuid) RENAME TO privacy_erase_before_reported_buyer;
CREATE FUNCTION ritc.privacy_erase_extension(target_household uuid,target_member uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 DELETE FROM ritc.operation_response r USING ritc.request_purchase_buyer b
 WHERE (r.household_id,r.operation_id)=(b.household_id,b.operation_id)
   AND b.household_id=target_household AND b.buyer_id=target_member;
 UPDATE ritc.operation o SET payload_digest=repeat('0',64) FROM ritc.request_purchase_buyer b
 WHERE (o.household_id,o.operation_id)=(b.household_id,b.operation_id)
   AND b.household_id=target_household AND b.buyer_id=target_member;
 DELETE FROM ritc.request_purchase_buyer WHERE household_id=target_household AND buyer_id=target_member;
 PERFORM ritc.privacy_erase_before_reported_buyer(target_household,target_member);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_extension(uuid,uuid) FROM PUBLIC;
