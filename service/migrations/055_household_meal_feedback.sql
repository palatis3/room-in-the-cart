-- Feedback has its own revision. It neither creates a cook operation nor changes a physical count.
CREATE TABLE ritc.household_meal_feedback (
  household_id uuid NOT NULL,
  cook_id uuid NOT NULL,
  member_id uuid NOT NULL,
  revision uuid NOT NULL,
  reactions text[] NOT NULL,
  updated_at timestamptz NOT NULL,
  PRIMARY KEY (household_id,cook_id,member_id),
  FOREIGN KEY (household_id,cook_id) REFERENCES ritc.shared_cook(household_id,operation_id) ON DELETE CASCADE,
  FOREIGN KEY (household_id,member_id) REFERENCES ritc.member(household_id,member_id) ON DELETE CASCADE,
  CHECK (cardinality(reactions) <= 4 AND array_position(reactions,NULL) IS NULL AND
    reactions <@ ARRAY['makeAgain','tooMuchEffort','childrenLikedIt','tooManyLeftovers']::text[])
);
ALTER TABLE ritc.household_meal_feedback ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.household_meal_feedback FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON ritc.household_meal_feedback TO ritc_app
  USING (household_id::text=(SELECT current_setting('app.household_id',true)))
  WITH CHECK (household_id::text=(SELECT current_setting('app.household_id',true)));
GRANT SELECT,INSERT,UPDATE,DELETE ON ritc.household_meal_feedback TO ritc_app;
CREATE INDEX meal_feedback_member ON ritc.household_meal_feedback(household_id,member_id);

CREATE TABLE ritc.meal_feedback_receipt (
 household_id uuid NOT NULL, client_key uuid NOT NULL, member_id uuid NOT NULL, device_id uuid NOT NULL,
 cook_id uuid NOT NULL, window_id uuid NOT NULL, request_digest text NOT NULL CHECK(length(request_digest)=64),
 accepted_revision uuid, PRIMARY KEY(household_id,client_key),
 FOREIGN KEY(household_id,cook_id) REFERENCES ritc.shared_cook(household_id,operation_id) ON DELETE CASCADE,
 FOREIGN KEY(household_id,member_id) REFERENCES ritc.member(household_id,member_id) ON DELETE CASCADE
);
ALTER TABLE ritc.meal_feedback_receipt ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.meal_feedback_receipt FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON ritc.meal_feedback_receipt TO ritc_app
 USING(household_id::text=(SELECT current_setting('app.household_id',true)))
 WITH CHECK(household_id::text=(SELECT current_setting('app.household_id',true)));
GRANT SELECT,INSERT,DELETE ON ritc.meal_feedback_receipt TO ritc_app;
CREATE INDEX meal_feedback_receipt_window ON ritc.meal_feedback_receipt(household_id,window_id);
CREATE INDEX meal_feedback_receipt_cook ON ritc.meal_feedback_receipt(household_id,cook_id);

CREATE FUNCTION ritc.clear_cook_feedback() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  DELETE FROM ritc.meal_feedback_receipt WHERE household_id=NEW.household_id AND cook_id=NEW.operation_id;
  DELETE FROM ritc.household_meal_feedback WHERE household_id=NEW.household_id AND cook_id=NEW.operation_id;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION ritc.clear_cook_feedback() FROM PUBLIC;
CREATE TRIGGER clear_cook_feedback AFTER UPDATE OF undone_by ON ritc.shared_cook FOR EACH ROW
  WHEN (NEW.undone_by IS NOT NULL) EXECUTE FUNCTION ritc.clear_cook_feedback();

CREATE FUNCTION ritc.clear_member_feedback() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  DELETE FROM ritc.meal_feedback_receipt WHERE household_id=NEW.household_id AND member_id=NEW.member_id;
  DELETE FROM ritc.household_meal_feedback WHERE household_id=NEW.household_id AND member_id=NEW.member_id;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION ritc.clear_member_feedback() FROM PUBLIC;
CREATE TRIGGER clear_member_feedback AFTER UPDATE OF state,organizer,pantry_editor ON ritc.member FOR EACH ROW
  WHEN (NEW.pantry_grant_epoch<>OLD.pantry_grant_epoch OR NEW.state<>OLD.state) EXECUTE FUNCTION ritc.clear_member_feedback();

ALTER FUNCTION ritc.privacy_erase_extension(uuid,uuid) RENAME TO privacy_erase_before_meal_feedback;
CREATE FUNCTION ritc.privacy_erase_extension(target_household uuid,target_member uuid) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 DELETE FROM ritc.meal_feedback_receipt WHERE household_id=target_household AND member_id=target_member;
 DELETE FROM ritc.household_meal_feedback WHERE household_id=target_household AND member_id=target_member;
 PERFORM ritc.privacy_erase_before_meal_feedback(target_household,target_member);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_extension(uuid,uuid) FROM PUBLIC;
