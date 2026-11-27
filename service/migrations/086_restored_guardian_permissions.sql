-- Accept signed erasure preimages and finish every archive segment before changing
-- the remaining families. A backup cannot establish that their permission is current.
CREATE FUNCTION ritc.retire_restored_guardian_permissions() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog SET row_security=off AS $$
BEGIN
 IF NOT ritc.is_final_restore_segment(NEW.run_id) THEN RETURN NEW; END IF;

 -- Use the ordinary, one-way withdrawal transitions. They retire the child's
 -- paired devices, replay windows, invitation, claim and sign-in challenges.
 UPDATE ritc.consent SET revoked_at=statement_timestamp() WHERE revoked_at IS NULL;
 UPDATE ritc.guardian_enrollment SET state='withdrawn',revision=revision+1
 WHERE state NOT IN ('withdrawn','cancelled','expired');
 UPDATE ritc.web_session s SET revoked_at=statement_timestamp()
 FROM ritc.member m WHERE (m.household_id,m.member_id)=(s.household_id,s.member_id)
 AND m.kind='child' AND s.revoked_at IS NULL;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ritc.retire_restored_guardian_permissions() FROM PUBLIC;
CREATE TRIGGER retire_restored_guardian_permissions AFTER UPDATE OF phase ON ritc.privacy_restore_run
 FOR EACH ROW WHEN (NEW.phase='local_app_erased' AND OLD.phase IS DISTINCT FROM NEW.phase)
 EXECUTE FUNCTION ritc.retire_restored_guardian_permissions();
