CREATE TABLE ritc.saved_week_change (
  household_id uuid NOT NULL,
  shop_id uuid NOT NULL,
  plan_id uuid NOT NULL,
  actor_id uuid NOT NULL,
  week_start date NOT NULL,
  authority_epoch integer NOT NULL,
  grant_revision integer NOT NULL,
  initial_revision integer NOT NULL,
  review_digest text NOT NULL,
  steps jsonb NOT NULL CHECK (jsonb_typeof(steps) = 'array'),
  receipts jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(receipts) = 'array'),
  stopped boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (household_id,shop_id,plan_id),
  FOREIGN KEY (household_id,shop_id) REFERENCES ritc.shop ON DELETE CASCADE,
  FOREIGN KEY (household_id,actor_id) REFERENCES ritc.member ON DELETE CASCADE
);
CREATE INDEX saved_week_latest ON ritc.saved_week_change(household_id,shop_id,authority_epoch,grant_revision,week_start,created_at DESC);
ALTER TABLE ritc.saved_week_change ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.saved_week_change FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON ritc.saved_week_change TO ritc_app
  USING(household_id::text=(SELECT current_setting('app.household_id',true)))
  WITH CHECK(household_id::text=(SELECT current_setting('app.household_id',true)));
GRANT SELECT,INSERT,UPDATE ON ritc.saved_week_change TO ritc_app;
ALTER FUNCTION ritc.privacy_erase_extension(uuid,uuid) RENAME TO privacy_erase_before_saved_week;
CREATE FUNCTION ritc.privacy_erase_extension(target_household uuid,target_member uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  DELETE FROM ritc.saved_week_change w WHERE w.household_id=target_household AND
    (w.actor_id=target_member OR EXISTS(SELECT 1 FROM ritc.shared_meal_revision m
      WHERE m.household_id=w.household_id AND m.shop_id=w.shop_id AND m.actor_id=target_member
      AND EXISTS(SELECT 1 FROM jsonb_array_elements(w.steps) s WHERE m.occurrence_id::text=s->>'id')));
  PERFORM ritc.privacy_erase_before_saved_week(target_household,target_member);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_extension(uuid,uuid) FROM PUBLIC;
