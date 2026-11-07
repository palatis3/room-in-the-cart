-- Bind a child's disclosure to the consent generation on the sending device.
-- A missing or erased receipt cannot establish an older disclosure's provenance.
ALTER TABLE ritc.request ADD COLUMN author_consent_id uuid;
UPDATE ritc.request r SET author_consent_id=d.guardian_consent_id
FROM ritc.operation o JOIN ritc.operation_response reply USING(household_id,operation_id)
JOIN ritc.device d USING(household_id,device_id)
WHERE o.kind='request.send' AND d.guardian_consent_id IS NOT NULL
 AND (o.household_id,o.actor_id)=(r.household_id,r.author_id)
 AND reply.response #>> '{request,requestId}'=r.request_id::text;

-- The destination request ID is also the server-assigned carry operation ID.
CREATE TABLE ritc.request_carry (
 household_id uuid NOT NULL, source_request_id uuid NOT NULL, target_request_id uuid NOT NULL,
 source_authority_epoch integer NOT NULL CHECK(source_authority_epoch>0),
 target_authority_epoch integer NOT NULL CHECK(target_authority_epoch>0),
 PRIMARY KEY(household_id,source_request_id), UNIQUE(household_id,target_request_id),
 CHECK(source_request_id<>target_request_id),
 FOREIGN KEY(household_id,source_request_id) REFERENCES ritc.request,
 FOREIGN KEY(household_id,target_request_id) REFERENCES ritc.request,
 FOREIGN KEY(household_id,target_request_id) REFERENCES ritc.operation DEFERRABLE INITIALLY DEFERRED
);
ALTER TABLE ritc.request_carry ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.request_carry FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON ritc.request_carry TO ritc_app
 USING(household_id::text=(SELECT current_setting('app.household_id',true)))
 WITH CHECK(household_id::text=(SELECT current_setting('app.household_id',true)));
GRANT SELECT,INSERT ON ritc.request_carry TO ritc_app;
CREATE INDEX request_next_shop ON ritc.request(household_id,request_id)
 WHERE route='next' AND status IN ('pending','clarified','deferred');

CREATE VIEW ritc.request_origin WITH (security_invoker=true) AS
 SELECT r.*, outgoing.source_request_id IS NOT NULL AS carried_forward,
 incoming.target_request_id IS NOT NULL AS from_previous_shop,
 m.alias AS author_alias, m.kind AS author_kind, (m.state='active' AND m.can_contribute) AS author_active,
 (SELECT c.notice_version FROM ritc.consent c
  JOIN ritc.guardian_relationship g USING(household_id,child_id,guardian_id)
  JOIN ritc.member guardian ON (guardian.household_id,guardian.member_id)=(c.household_id,c.guardian_id)
  WHERE (c.household_id,c.consent_id,c.child_id)=(r.household_id,r.author_consent_id,r.author_id)
  AND c.revoked_at IS NULL AND g.revoked_at IS NULL AND guardian.state='active' AND guardian.kind='adult'
  AND EXISTS(SELECT FROM ritc.guardian_enrollment e WHERE (e.household_id,e.consent_id)=(c.household_id,c.consent_id) AND e.state='active')
 ) AS live_notice
 FROM ritc.request r JOIN ritc.member m ON (m.household_id,m.member_id)=(r.household_id,r.author_id)
 LEFT JOIN ritc.request_carry outgoing ON (outgoing.household_id,outgoing.source_request_id)=(r.household_id,r.request_id)
 LEFT JOIN ritc.request_carry incoming ON (incoming.household_id,incoming.target_request_id)=(r.household_id,r.request_id);
GRANT SELECT ON ritc.request_origin TO ritc_app;

-- The original and all descendants retain the actual author. The existing
-- eraser scrubs all of their text, linked lines, snapshots and decision previews.
-- Also forget receipts made on their behalf by a different shopper.
ALTER FUNCTION ritc.privacy_erase_extension(uuid,uuid) RENAME TO privacy_erase_before_request_carry;
CREATE FUNCTION ritc.privacy_erase_extension(target_household uuid,target_member uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 DELETE FROM ritc.operation_response reply USING ritc.request_carry c,ritc.request r
 WHERE (reply.household_id,reply.operation_id)=(c.household_id,c.target_request_id)
 AND (r.household_id,r.request_id)=(c.household_id,c.target_request_id)
 AND r.household_id=target_household AND r.author_id=target_member;
 UPDATE ritc.operation o SET payload_digest=repeat('0',64) FROM ritc.request_carry c,ritc.request r
 WHERE (o.household_id,o.operation_id)=(c.household_id,c.target_request_id)
 AND (r.household_id,r.request_id)=(c.household_id,c.target_request_id)
 AND r.household_id=target_household AND r.author_id=target_member;
 UPDATE ritc.request SET author_consent_id=NULL WHERE household_id=target_household AND author_id=target_member;
 PERFORM ritc.privacy_erase_before_request_carry(target_household,target_member);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_extension(uuid,uuid) FROM PUBLIC;
