-- The backup cannot attest that a planner's unfinished instructions or meal shares
-- are still wanted. Keep committed groceries, dinner choices and past step receipts.
-- Wait until every signed preimage has been used. Earlier segments can contain
-- invitation or consent state required to replay a later acceptance.
CREATE FUNCTION ritc.is_final_restore_segment(id uuid) RETURNS boolean
LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
 SELECT NOT EXISTS (
   SELECT FROM ritc.privacy_restore_window_segment s
   JOIN ritc.privacy_restore_window w USING(window_id)
   WHERE s.run_id=id AND s.position<w.segment_count
 );
$$;
REVOKE ALL ON FUNCTION ritc.is_final_restore_segment(uuid) FROM PUBLIC;

CREATE FUNCTION ritc.retire_restored_meal_permissions() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog SET row_security=off AS $$
BEGIN
 IF NOT ritc.is_final_restore_segment(NEW.run_id) THEN RETURN NEW; END IF;
 UPDATE ritc.invite SET revoked_at=statement_timestamp()
 WHERE dinner_occurrence_id IS NOT NULL AND revoked_at IS NULL AND expires_at>statement_timestamp();

 UPDATE ritc.shared_repeat_week w SET stopped=true
 WHERE NOT stopped AND EXISTS (
   SELECT FROM jsonb_array_elements(w.steps) s WHERE NOT (w.receipts ? (s->>'targetId'))
 );
 UPDATE ritc.saved_week_change SET stopped=true
 WHERE NOT stopped AND jsonb_array_length(receipts)<jsonb_array_length(steps);

 -- This also clears the shared instruction through erase_withdrawn_step.
 UPDATE ritc.adult_check SET withdrawn=true,answer=NULL,quantity=NULL,answered_at=NULL,reviewed=false
 WHERE NOT withdrawn;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ritc.retire_restored_meal_permissions() FROM PUBLIC;
CREATE TRIGGER retire_restored_meal_permissions AFTER UPDATE OF phase ON ritc.privacy_restore_run
 FOR EACH ROW WHEN (NEW.phase='local_app_erased' AND OLD.phase IS DISTINCT FROM NEW.phase)
 EXECUTE FUNCTION ritc.retire_restored_meal_permissions();
