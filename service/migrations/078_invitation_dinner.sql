-- Keep the occurrence on the service. An invitation preview contains only household and role.
ALTER TABLE ritc.invite
  ADD COLUMN dinner_shop_id uuid,
  ADD COLUMN dinner_occurrence_id uuid,
  ADD COLUMN dinner_authority_epoch integer,
  ADD CONSTRAINT invitation_dinner_scope CHECK (
    (dinner_shop_id IS NULL AND dinner_occurrence_id IS NULL AND dinner_authority_epoch IS NULL)
    OR (kind='adult_contributor' AND grant_id IS NULL AND dinner_shop_id IS NOT NULL
        AND dinner_occurrence_id IS NOT NULL AND dinner_authority_epoch IS NOT NULL AND dinner_authority_epoch>0)
  );
