-- The scheduled worker receives counts only. Queue and adjudication remain operator-only.
CREATE FUNCTION ritc.moderation_maintenance(batch_size integer, apply_prune boolean)
RETURNS TABLE(pending bigint, expired_unreviewed bigint, expired_cases bigint,
              expired_receipts bigint, pruned_unreviewed bigint, more_expired boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF batch_size IS NULL OR batch_size NOT BETWEEN 1 AND 1000 OR apply_prune IS NULL THEN
  RAISE EXCEPTION 'invalid moderation maintenance batch';
 END IF;
 expired_cases := 0;
 expired_receipts := 0;
 pruned_unreviewed := 0;
 IF apply_prune THEN
  WITH eligible AS (
   SELECT case_id FROM ritc.moderation_case WHERE expires_at<=now()
   ORDER BY expires_at,case_id LIMIT batch_size FOR UPDATE SKIP LOCKED
  ), removed AS (
   DELETE FROM ritc.moderation_case c USING eligible e WHERE c.case_id=e.case_id RETURNING c.resolution
  )
  SELECT count(*),count(*) FILTER (WHERE resolution IS NULL)
   INTO expired_cases,pruned_unreviewed FROM removed;

  WITH eligible AS (
   SELECT household_id,reporter_id,client_key FROM ritc.moderation_receipt WHERE expires_at<=now()
   ORDER BY expires_at,receipt_id LIMIT batch_size FOR UPDATE SKIP LOCKED
  )
  DELETE FROM ritc.moderation_receipt r USING eligible e
   WHERE (r.household_id,r.reporter_id,r.client_key)=(e.household_id,e.reporter_id,e.client_key);
  GET DIAGNOSTICS expired_receipts=ROW_COUNT;
 END IF;

 SELECT w.pending,w.expired_unreviewed INTO pending,expired_unreviewed FROM ritc.moderation_workload() w;
 more_expired := EXISTS(SELECT 1 FROM ritc.moderation_case WHERE expires_at<=now())
   OR EXISTS(SELECT 1 FROM ritc.moderation_receipt WHERE expires_at<=now());
 RETURN NEXT;
END $$;
REVOKE ALL ON FUNCTION ritc.moderation_maintenance(integer,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ritc.moderation_maintenance(integer,boolean) TO ritc_worker;
