-- Share only one reviewed instruction. Private recipe and timer IDs stay on-device.
ALTER TABLE ritc.adult_check
  DROP CONSTRAINT adult_check_kind_check,
  DROP CONSTRAINT adult_check_check3,
  ADD COLUMN step_text text,
  ADD COLUMN step_sender uuid,
  ADD CHECK (kind IN ('attendance','cupboard','cookStep')),
  ADD CHECK (answer IS NULL OR
    (kind='attendance' AND answer IN ('home','latePlate','out')) OR
    (kind='cupboard' AND answer IN ('enough','low','cannotCheck')) OR
    (kind='cookStep' AND answer IN ('accepted','declined'))),
  ADD CHECK ((kind='cookStep' AND step_sender IS NOT NULL AND step_sender IN (shopper_id,recipient_id)
    AND ((withdrawn AND step_text IS NULL) OR (NOT withdrawn AND step_text IS NOT NULL AND length(step_text) BETWEEN 1 AND 240)))
    OR (kind<>'cookStep' AND step_sender IS NULL AND step_text IS NULL));

-- Each existing role/seat/block/billing revocation and user withdrawal uses the
-- same retirement path. Preserve the operation ID for retry safety until expiry.
CREATE FUNCTION ritc.erase_withdrawn_step() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  NEW.step_text := NULL;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ritc.erase_withdrawn_step() FROM PUBLIC;
CREATE TRIGGER erase_withdrawn_step BEFORE UPDATE ON ritc.adult_check
  FOR EACH ROW WHEN (NEW.withdrawn AND NEW.step_text IS NOT NULL) EXECUTE FUNCTION ritc.erase_withdrawn_step();

ALTER TABLE ritc.moderation_case DROP CONSTRAINT moderation_case_source_kind_check,
  ADD CHECK(source_kind IN ('request','clarification','instruction','suggestion','cookCopy','productReference','substitution','pickingRow','cookStep'));
