-- Immutable acceptance-time evidence. No historical eligibility backfill.
-- Register together with transaction capture, scoped compensation and erasure.
CREATE TABLE ritc.request_acceptance_effect (
 household_id uuid NOT NULL, shop_id uuid NOT NULL, operation_id uuid NOT NULL,
 request_id uuid NOT NULL, author_id uuid NOT NULL, actor_id uuid NOT NULL,
 device_id uuid NOT NULL, authority_epoch integer NOT NULL CHECK(authority_epoch>0), author_consent_id uuid,
 base_shop_revision integer NOT NULL CHECK(base_shop_revision>0),
 result_shop_revision integer NOT NULL CHECK(result_shop_revision=base_shop_revision+1),
 base_request_revision integer NOT NULL CHECK(base_request_revision>0),
 result_request_revision integer NOT NULL CHECK(result_request_revision=base_request_revision+1),
 certificate jsonb, certificate_digest text,
 PRIMARY KEY(household_id,operation_id),
 CHECK((certificate IS NULL)=(certificate_digest IS NULL)),
 CHECK(certificate_digest IS NULL OR certificate_digest ~ '^[a-f0-9]{64}$' AND certificate_digest<>repeat('0',64)),
 CHECK(certificate IS NULL OR (certificate->>'schemaVersion'='1'
   AND certificate->>'householdId'=household_id::text AND certificate->>'shopId'=shop_id::text
   AND certificate->>'operationId'=operation_id::text AND certificate->>'requestId'=request_id::text
   AND certificate->>'authorId'=author_id::text AND certificate->>'actorId'=actor_id::text
   AND certificate->>'deviceId'=device_id::text AND (certificate->>'authorityEpoch')::integer=authority_epoch
   AND certificate ? 'consentId' AND (certificate->>'consentId')::uuid IS NOT DISTINCT FROM author_consent_id
   AND (certificate->>'baseShopRevision')::integer=base_shop_revision
   AND (certificate->>'resultShopRevision')::integer=result_shop_revision
   AND (certificate#>>'{before,revision}')::integer=base_request_revision
   AND (certificate#>>'{after,revision}')::integer=result_request_revision) IS TRUE),
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,
 FOREIGN KEY(household_id,request_id) REFERENCES ritc.request,
 FOREIGN KEY(household_id,author_id) REFERENCES ritc.member,
 FOREIGN KEY(household_id,actor_id,device_id) REFERENCES ritc.device(household_id,member_id,device_id),
 -- Operation is inserted after its shopper action; never use an immediate FK.
 FOREIGN KEY(household_id,operation_id) REFERENCES ritc.operation DEFERRABLE INITIALLY DEFERRED,
 FOREIGN KEY(household_id,shop_id,base_shop_revision) REFERENCES ritc.shop_snapshot(household_id,shop_id,revision) DEFERRABLE INITIALLY DEFERRED,
 FOREIGN KEY(household_id,shop_id,result_shop_revision) REFERENCES ritc.shop_snapshot(household_id,shop_id,revision) DEFERRABLE INITIALLY DEFERRED
);
-- Content-free provenance survives retirement of request_link and payload erasure.
-- Includes the acceptance actor, actual author and any additional source owners
-- whose reviewed evidence was copied. Never reconstruct this from current links.
CREATE TABLE ritc.request_acceptance_source_member (
 household_id uuid NOT NULL, operation_id uuid NOT NULL, member_id uuid NOT NULL,
 PRIMARY KEY(household_id,operation_id,member_id),
 FOREIGN KEY(household_id,operation_id) REFERENCES ritc.request_acceptance_effect,
 FOREIGN KEY(household_id,member_id) REFERENCES ritc.member
);
ALTER TABLE ritc.request_acceptance_effect ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.request_acceptance_effect FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON ritc.request_acceptance_effect TO ritc_app
 USING(household_id::text=(SELECT current_setting('app.household_id',true)))
 WITH CHECK(household_id::text=(SELECT current_setting('app.household_id',true)));
ALTER TABLE ritc.request_acceptance_source_member ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.request_acceptance_source_member FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON ritc.request_acceptance_source_member TO ritc_app
 USING(household_id::text=(SELECT current_setting('app.household_id',true)))
 WITH CHECK(household_id::text=(SELECT current_setting('app.household_id',true)));
GRANT SELECT,INSERT ON ritc.request_acceptance_effect,ritc.request_acceptance_source_member TO ritc_app;
CREATE TRIGGER request_acceptance_immutable BEFORE UPDATE OR DELETE ON ritc.request_acceptance_effect
 FOR EACH ROW EXECUTE FUNCTION ritc.immutable_row();
CREATE TRIGGER request_acceptance_origin_immutable BEFORE UPDATE OR DELETE ON ritc.request_acceptance_source_member
 FOR EACH ROW EXECUTE FUNCTION ritc.immutable_row();

CREATE INDEX request_acceptance_origin_member ON ritc.request_acceptance_source_member(household_id,member_id);
CREATE TABLE ritc.request_acceptance_inverse (
 household_id uuid NOT NULL,shop_id uuid NOT NULL,operation_id uuid NOT NULL,target_operation_id uuid NOT NULL,
 request_id uuid NOT NULL,actor_id uuid NOT NULL,device_id uuid NOT NULL,authority_epoch integer NOT NULL CHECK(authority_epoch>0),
 client_key uuid NOT NULL,payload_digest text NOT NULL CHECK(payload_digest ~ '^[a-f0-9]{64}$'),acceptance_digest text,
 receipt jsonb,
 PRIMARY KEY(household_id,operation_id),UNIQUE(household_id,target_operation_id),
 CHECK(operation_id<>target_operation_id),CHECK((receipt IS NULL)=(acceptance_digest IS NULL)),
 CHECK(acceptance_digest IS NULL OR acceptance_digest ~ '^[a-f0-9]{64}$'),
 CHECK(receipt IS NULL OR ((receipt->>'operationId')::uuid=operation_id AND (receipt->>'shopId')::uuid=shop_id
  AND (receipt->>'requestId')::uuid=request_id AND (receipt->>'authorityEpoch')::integer=authority_epoch
  AND receipt->>'kind'='request.undoAcceptance' AND receipt->>'disposition'='acceptanceUndone') IS TRUE),
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,
 FOREIGN KEY(household_id,request_id) REFERENCES ritc.request,
 FOREIGN KEY(household_id,actor_id,device_id) REFERENCES ritc.device(household_id,member_id,device_id),
 FOREIGN KEY(household_id,operation_id) REFERENCES ritc.operation DEFERRABLE INITIALLY DEFERRED,
 FOREIGN KEY(household_id,target_operation_id) REFERENCES ritc.request_acceptance_effect
);
CREATE TABLE ritc.request_acceptance_preview (
 household_id uuid NOT NULL,shop_id uuid NOT NULL,preview_id uuid NOT NULL,operation_id uuid NOT NULL,
 actor_id uuid NOT NULL,device_id uuid NOT NULL,authority_epoch integer NOT NULL,shop_revision integer NOT NULL,
 target_operation_id uuid NOT NULL,request_id uuid NOT NULL,request_revision integer NOT NULL,
 intent jsonb NOT NULL,result jsonb NOT NULL,accepted_digest text NOT NULL CHECK(accepted_digest ~ '^[a-f0-9]{64}$'),
 created_at timestamptz NOT NULL,expires_at timestamptz NOT NULL,
 PRIMARY KEY(household_id,preview_id),UNIQUE(household_id,operation_id),
 CHECK(expires_at>created_at AND expires_at<=created_at+interval '10 minutes'),
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,
 FOREIGN KEY(household_id,target_operation_id) REFERENCES ritc.request_acceptance_effect,
 FOREIGN KEY(household_id,request_id) REFERENCES ritc.request,
 FOREIGN KEY(household_id,actor_id,device_id) REFERENCES ritc.device(household_id,member_id,device_id)
);
CREATE INDEX request_acceptance_preview_expiry ON ritc.request_acceptance_preview(household_id,expires_at);
DO $$ DECLARE t text;BEGIN
 FOREACH t IN ARRAY ARRAY['request_acceptance_inverse','request_acceptance_preview'] LOOP
  EXECUTE format('ALTER TABLE ritc.%I ENABLE ROW LEVEL SECURITY',t);EXECUTE format('ALTER TABLE ritc.%I FORCE ROW LEVEL SECURITY',t);
  EXECUTE format('CREATE POLICY tenant_scope ON ritc.%I TO ritc_app USING(household_id::text=(SELECT current_setting(''app.household_id'',true))) WITH CHECK(household_id::text=(SELECT current_setting(''app.household_id'',true)))',t);
  EXECUTE format('GRANT SELECT,INSERT ON ritc.%I TO ritc_app',t);
 END LOOP;
END $$;
GRANT DELETE ON ritc.request_acceptance_preview TO ritc_app;
CREATE TRIGGER request_acceptance_inverse_immutable BEFORE UPDATE OR DELETE ON ritc.request_acceptance_inverse FOR EACH ROW EXECUTE FUNCTION ritc.immutable_row();
-- A constrained deletion, never a general request_link DELETE grant. The server
-- has revalidated the entire preview; SQL also fences its exact original link,
-- pending operation, current request and shop bases before releasing the basket FK.
CREATE FUNCTION ritc.retire_request_acceptance(h uuid,s uuid,p uuid,o uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE target record;removed integer;
BEGIN
 IF h::text IS DISTINCT FROM current_setting('app.household_id',true) THEN RAISE EXCEPTION 'tenant scope' USING ERRCODE='42501';END IF;
 SELECT v.request_id,v.target_operation_id,e.certificate INTO target
 FROM ritc.request_acceptance_preview v JOIN ritc.request_acceptance_effect e ON (e.household_id,e.operation_id)=(v.household_id,v.target_operation_id)
 JOIN ritc.shop sh ON (sh.household_id,sh.shop_id)=(v.household_id,v.shop_id)
 JOIN ritc.request r ON (r.household_id,r.request_id)=(v.household_id,v.request_id)
 WHERE v.household_id=h AND v.shop_id=s AND v.preview_id=p AND v.operation_id=o AND v.expires_at>clock_timestamp()
 AND e.certificate IS NOT NULL AND sh.phase='draft' AND sh.shopper_id=v.actor_id AND sh.authority_epoch=v.authority_epoch AND sh.revision=v.shop_revision
 AND r.shop_id=s AND r.revision=v.request_revision AND r.status='added' AND r.route='current';
 IF NOT FOUND THEN RAISE EXCEPTION 'request transition changed' USING ERRCODE='23514';END IF;
 DELETE FROM ritc.request_link WHERE household_id=h AND shop_id=s AND request_id=target.request_id AND operation_id=target.target_operation_id
 AND line_id=(target.certificate#>>'{afterLink,lineId}')::uuid AND reviewed_revision=(target.certificate#>>'{afterLink,reviewedRevision}')::integer;
 GET DIAGNOSTICS removed=ROW_COUNT;IF removed<>1 THEN RAISE EXCEPTION 'request link changed' USING ERRCODE='23514';END IF;
END $$;
REVOKE ALL ON FUNCTION ritc.retire_request_acceptance(uuid,uuid,uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.retire_request_acceptance(uuid,uuid,uuid,uuid) TO ritc_app;

-- Independent origin rows survive live-link retirement. Erasure first removes
-- exact accepted Add label copies, then makes all acceptance/inverse proof inert.
ALTER FUNCTION ritc.privacy_erase_extension(uuid,uuid) RENAME TO privacy_erase_before_request_acceptance;
CREATE FUNCTION ritc.privacy_erase_extension(h uuid,m uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE e record;source_line text;source_label text;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM ritc.request_acceptance_source_member WHERE household_id=h AND member_id=m)
 AND NOT EXISTS(SELECT 1 FROM ritc.request_acceptance_preview WHERE household_id=h) THEN
  PERFORM ritc.privacy_erase_before_request_acceptance(h,m);RETURN;
 END IF;
 IF NOT ritc.privacy_erasure_authorized() THEN RAISE EXCEPTION 'erasure authority required';END IF;
 DELETE FROM ritc.request_acceptance_preview WHERE household_id=h;
 FOR e IN SELECT a.* FROM ritc.request_acceptance_effect a JOIN ritc.request_acceptance_source_member p USING(household_id,operation_id) WHERE p.household_id=h AND p.member_id=m LOOP
  IF e.certificate#>>'{decision,choice}'='add' THEN
   source_line=e.certificate#>>'{decision,line,lineId}';source_label=e.certificate#>>'{decision,line,originalItem}';
   UPDATE ritc.basket_line SET original_item='Removed item' WHERE household_id=h AND shop_id=e.shop_id AND basket_line.line_id::text=source_line AND original_item=source_label;
   UPDATE ritc.shop_snapshot SET snapshot=jsonb_set(snapshot,'{lines}',COALESCE((SELECT jsonb_agg(CASE WHEN x->>'lineId'=source_line AND x->>'originalItem'=source_label THEN jsonb_set(x,'{originalItem}','"Removed item"') ELSE x END ORDER BY ord) FROM jsonb_array_elements(COALESCE(snapshot->'lines','[]')) WITH ORDINALITY AS xs(x,ord)),'[]')),digest=repeat('0',64)
    WHERE household_id=h AND shop_id=e.shop_id AND EXISTS(SELECT 1 FROM jsonb_array_elements(COALESCE(snapshot->'lines','[]')) x WHERE x->>'lineId'=source_line AND x->>'originalItem'=source_label);
  END IF;
  DELETE FROM ritc.operation_response WHERE household_id=h AND (operation_id=e.operation_id OR operation_id IN(SELECT operation_id FROM ritc.request_acceptance_inverse WHERE household_id=h AND target_operation_id=e.operation_id));
  UPDATE ritc.operation SET payload_digest=repeat('0',64) WHERE household_id=h AND (operation_id=e.operation_id OR operation_id IN(SELECT operation_id FROM ritc.request_acceptance_inverse WHERE household_id=h AND target_operation_id=e.operation_id));
  UPDATE ritc.request_acceptance_inverse SET acceptance_digest=NULL,receipt=NULL,payload_digest=repeat('0',64) WHERE household_id=h AND target_operation_id=e.operation_id;
  UPDATE ritc.request_acceptance_effect SET certificate=NULL,certificate_digest=NULL WHERE household_id=h AND operation_id=e.operation_id;
 END LOOP;
 PERFORM ritc.privacy_erase_before_request_acceptance(h,m);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_extension(uuid,uuid) FROM PUBLIC;
