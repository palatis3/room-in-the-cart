-- Private in-app notices and consent to one exact recipient. Nothing is exposed through PostgREST.
CREATE TABLE ritc.pickup_last_call (
 household_id uuid NOT NULL, shop_id uuid NOT NULL, sender_id uuid NOT NULL,
 authority_epoch integer NOT NULL, revision integer NOT NULL CHECK(revision>0), cutoff_at timestamptz NOT NULL,
 PRIMARY KEY(household_id,shop_id), FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop ON DELETE CASCADE,
 FOREIGN KEY(household_id,sender_id) REFERENCES ritc.member ON DELETE CASCADE
);
CREATE TABLE ritc.pickup_last_call_recipient (
 household_id uuid NOT NULL, shop_id uuid NOT NULL, member_id uuid NOT NULL,
 response text CHECK(response IN ('pass','sent')), muted boolean NOT NULL DEFAULT false,
 PRIMARY KEY(household_id,shop_id,member_id),
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.pickup_last_call ON DELETE CASCADE,
 FOREIGN KEY(household_id,member_id) REFERENCES ritc.member ON DELETE CASCADE
);
CREATE INDEX pickup_recipient_member ON ritc.pickup_last_call_recipient(household_id,member_id);
CREATE TABLE ritc.adult_product_reference (
 household_id uuid NOT NULL, request_id uuid NOT NULL, shop_id uuid NOT NULL, author_id uuid NOT NULL, recipient_id uuid NOT NULL,
 authority_epoch integer NOT NULL, revision integer NOT NULL CHECK(revision>0), publication_id uuid NOT NULL UNIQUE,
 reported boolean NOT NULL DEFAULT false, client_key uuid NOT NULL, fingerprint text NOT NULL, brand text, package_size text, barcode text, description text,
 crop_width smallint, crop_height smallint, pixels bytea, media_status text CHECK(media_status IN ('pending','approved','rejected')),
 expires_at timestamptz NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), media_reviewed_at timestamptz, media_reviewed_by name,
 PRIMARY KEY(household_id,request_id), CHECK(author_id<>recipient_id),
 CHECK((pixels IS NULL AND crop_width IS NULL AND crop_height IS NULL) OR
       (pixels IS NOT NULL AND crop_width IS NOT NULL AND crop_height IS NOT NULL AND media_status IS NOT NULL AND
        crop_width BETWEEN 8 AND 192 AND crop_height BETWEEN 8 AND 192 AND octet_length(pixels)=crop_width*crop_height*3)),
 CHECK(description IS NOT NULL OR (brand IS NULL AND package_size IS NULL AND barcode IS NULL AND pixels IS NULL)),
 FOREIGN KEY(household_id,request_id) REFERENCES ritc.request ON DELETE CASCADE,
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop ON DELETE CASCADE,
 FOREIGN KEY(household_id,author_id) REFERENCES ritc.member ON DELETE CASCADE,
 FOREIGN KEY(household_id,recipient_id) REFERENCES ritc.member ON DELETE CASCADE
);
CREATE INDEX product_reference_expiry ON ritc.adult_product_reference(expires_at) WHERE description IS NOT NULL;
CREATE INDEX product_reference_shop ON ritc.adult_product_reference(household_id,shop_id);
CREATE INDEX product_reference_author ON ritc.adult_product_reference(household_id,author_id);
CREATE INDEX product_reference_recipient ON ritc.adult_product_reference(household_id,recipient_id);
CREATE INDEX product_reference_queue ON ritc.adult_product_reference(created_at,publication_id) WHERE media_status='pending';
ALTER TABLE ritc.moderation_case DROP CONSTRAINT moderation_case_source_kind_check,
 ADD CHECK(source_kind IN ('request','clarification','instruction','suggestion','cookCopy','productReference'));
DO $$ DECLARE relation text; BEGIN
 FOREACH relation IN ARRAY ARRAY['pickup_last_call','pickup_last_call_recipient','adult_product_reference'] LOOP
  EXECUTE format('ALTER TABLE ritc.%I ENABLE ROW LEVEL SECURITY',relation);
  EXECUTE format('ALTER TABLE ritc.%I FORCE ROW LEVEL SECURITY',relation);
  EXECUTE format('CREATE POLICY tenant_scope ON ritc.%I TO ritc_app USING(household_id::text=(SELECT current_setting(''app.household_id'',true))) WITH CHECK(household_id::text=(SELECT current_setting(''app.household_id'',true)))',relation);
  EXECUTE format('GRANT SELECT,INSERT,UPDATE ON ritc.%I TO ritc_app',relation);
 END LOOP;
 IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='ritc_media_moderator') THEN
  CREATE ROLE ritc_media_moderator NOLOGIN NOSUPERUSER NOBYPASSRLS;
 END IF;
END $$;

CREATE FUNCTION ritc.pickup_cutoff_passed(h uuid,s uuid,viewer uuid,as_of timestamptz) RETURNS boolean
LANGUAGE sql STABLE SECURITY INVOKER SET search_path=pg_catalog AS $$
 SELECT EXISTS(SELECT FROM ritc.pickup_last_call c JOIN ritc.pickup_last_call_recipient r USING(household_id,shop_id)
  WHERE c.household_id=h AND c.shop_id=s AND r.member_id=viewer AND viewer=ritc.content_viewer() AND c.cutoff_at<=as_of
  AND ritc.shared_content_visible(h,viewer,c.sender_id,'lastCall',s,1,c.revision))
$$;
REVOKE ALL ON FUNCTION ritc.pickup_cutoff_passed(uuid,uuid,uuid,timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.pickup_cutoff_passed(uuid,uuid,uuid,timestamptz) TO ritc_app;

CREATE POLICY reference_participants ON ritc.adult_product_reference AS RESTRICTIVE TO ritc_app
 USING (ritc.content_viewer() IN (author_id,recipient_id))
 WITH CHECK (ritc.content_viewer() IN (author_id,recipient_id));

-- No copied evidence bucket. Reviewers can access only current pending, opt-in pixels.
CREATE FUNCTION ritc.product_media_queue() RETURNS TABLE(publication_id uuid,expires_at timestamptz,description text,width smallint,height smallint,pixels bytea)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT r.publication_id,r.expires_at,r.description,r.crop_width,r.crop_height,r.pixels
 FROM ritc.adult_product_reference r WHERE r.media_status='pending' AND r.expires_at>now()
 ORDER BY r.created_at,r.publication_id LIMIT 10
$$;
CREATE FUNCTION ritc.product_media_resolve(target uuid, verdict text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF verdict IS NULL OR verdict NOT IN ('approved','rejected') THEN RAISE EXCEPTION 'invalid decision'; END IF;
 UPDATE ritc.adult_product_reference SET media_status=verdict,media_reviewed_at=clock_timestamp(),media_reviewed_by=session_user,
   pixels=CASE WHEN verdict='approved' THEN pixels END,
   crop_width=CASE WHEN verdict='approved' THEN crop_width END,crop_height=CASE WHEN verdict='approved' THEN crop_height END
 WHERE publication_id=target AND media_status='pending' AND expires_at>clock_timestamp();
 RETURN FOUND;
END $$;
REVOKE ALL ON FUNCTION ritc.product_media_queue(),ritc.product_media_resolve(uuid,text) FROM PUBLIC;
GRANT USAGE ON SCHEMA ritc TO ritc_media_moderator;
GRANT EXECUTE ON FUNCTION ritc.product_media_queue(),ritc.product_media_resolve(uuid,text) TO ritc_media_moderator;

-- Keep the revision when clearing the content, so a stale offline write cannot recreate a removed reference.
CREATE FUNCTION ritc.prune_product_references(batch_size integer) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE cleaned integer;
BEGIN
 WITH expired AS (SELECT publication_id FROM ritc.adult_product_reference WHERE expires_at<=clock_timestamp() AND description IS NOT NULL
  ORDER BY expires_at LIMIT greatest(1,least(batch_size,100)) FOR UPDATE SKIP LOCKED)
 UPDATE ritc.adult_product_reference r SET revision=revision+1,brand=NULL,package_size=NULL,barcode=NULL,description=NULL,
  pixels=NULL,crop_width=NULL,crop_height=NULL,media_status=NULL,media_reviewed_at=NULL,media_reviewed_by=NULL,fingerprint=''
 FROM expired e WHERE r.publication_id=e.publication_id;
 GET DIAGNOSTICS cleaned=ROW_COUNT; RETURN cleaned;
END $$;
REVOKE ALL ON FUNCTION ritc.prune_product_references(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.prune_product_references(integer) TO ritc_worker;

CREATE FUNCTION ritc.clear_adult_pickup_scope() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF TG_TABLE_NAME='shop' THEN
  DELETE FROM ritc.pickup_last_call WHERE household_id=NEW.household_id AND shop_id=NEW.shop_id;
  DELETE FROM ritc.adult_product_reference WHERE household_id=NEW.household_id AND shop_id=NEW.shop_id;
 ELSIF TG_TABLE_NAME='member' THEN
  DELETE FROM ritc.pickup_last_call_recipient WHERE household_id=NEW.household_id AND member_id=NEW.member_id;
  DELETE FROM ritc.pickup_last_call WHERE household_id=NEW.household_id AND sender_id=NEW.member_id AND NEW.state<>'active';
  DELETE FROM ritc.adult_product_reference WHERE household_id=NEW.household_id AND
   (author_id=NEW.member_id OR (recipient_id=NEW.member_id AND (NEW.state<>'active' OR NEW.kind<>'adult')));
 ELSE
  UPDATE ritc.adult_product_reference SET revision=revision+1,brand=NULL,package_size=NULL,barcode=NULL,
   description=NULL,pixels=NULL,crop_width=NULL,crop_height=NULL,media_status=NULL,media_reviewed_at=NULL,media_reviewed_by=NULL,fingerprint=''
   WHERE household_id=NEW.household_id AND request_id=NEW.request_id AND description IS NOT NULL;
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ritc.clear_adult_pickup_scope() FROM PUBLIC;
CREATE TRIGGER end_pickup_shop_scope AFTER UPDATE ON ritc.shop FOR EACH ROW
 WHEN(NEW.authority_epoch<>OLD.authority_epoch OR NEW.shopper_id<>OLD.shopper_id OR (NEW.phase='closed' AND OLD.phase<>'closed'))
 EXECUTE FUNCTION ritc.clear_adult_pickup_scope();
CREATE TRIGGER end_pickup_member_scope AFTER UPDATE ON ritc.member FOR EACH ROW
 WHEN(NEW.state<>OLD.state OR NEW.erased_at IS DISTINCT FROM OLD.erased_at OR NEW.kind<>OLD.kind OR (OLD.can_contribute AND NOT NEW.can_contribute))
 EXECUTE FUNCTION ritc.clear_adult_pickup_scope();
CREATE TRIGGER end_pickup_request_scope AFTER UPDATE ON ritc.request FOR EACH ROW
 WHEN(NEW.original_item IS DISTINCT FROM OLD.original_item OR NEW.own_quantity IS DISTINCT FROM OLD.own_quantity OR
   (NEW.status<>OLD.status AND NEW.status IN ('withdrawn','dismissed','handled','deferred')))
 EXECUTE FUNCTION ritc.clear_adult_pickup_scope();

-- Restored backups cannot attest to subsequent withdrawals, replacements, blocks or passes.
-- The quarantined restore process registers a new run before it can open the destination.
CREATE FUNCTION ritc.discard_restored_pickup_shares() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 DELETE FROM ritc.adult_product_reference;
 DELETE FROM ritc.pickup_last_call;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ritc.discard_restored_pickup_shares() FROM PUBLIC;
CREATE TRIGGER discard_restored_pickup_shares AFTER INSERT ON ritc.privacy_restore_run
 FOR EACH ROW EXECUTE FUNCTION ritc.discard_restored_pickup_shares();
