CREATE OR REPLACE FUNCTION ritc.privacy_cleanup(batch_size integer)
RETURNS TABLE(receipts_cleared integer, jobs_purged integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE
 old_job record;
 n integer := greatest(1, least(batch_size, 100));
 cutoff timestamptz := clock_timestamp();
BEGIN
 receipts_cleared := 0;
 jobs_purged := 0;
 FOR old_job IN
  SELECT j.job_id, j.receipt_hash, j.marker_until
  FROM ritc.privacy_job j
  WHERE j.state = 'complete'
    AND j.receipt_until <= cutoff
    AND (j.receipt_hash <> repeat('0', 64) OR j.marker_until <= cutoff)
    AND NOT EXISTS (SELECT 1 FROM ritc.privacy_restore_job r WHERE r.job_id = j.job_id)
    AND NOT EXISTS (
     SELECT 1 FROM ritc.privacy_journal_outbox e
     WHERE e.job_id = j.job_id
       AND NOT EXISTS (SELECT 1 FROM ritc.privacy_journal_ack a WHERE a.event_id = e.event_id)
    )
  ORDER BY j.marker_until, j.job_id
  FOR UPDATE SKIP LOCKED LIMIT n
 LOOP
  IF old_job.receipt_hash <> repeat('0', 64) THEN
   UPDATE ritc.privacy_job
   SET receipt_hash = repeat('0', 64), payload_digest = repeat('0', 64)
   WHERE job_id = old_job.job_id;
   receipts_cleared := receipts_cleared + 1;
  END IF;
  IF old_job.marker_until <= cutoff THEN
   DELETE FROM ritc.privacy_target WHERE job_id = old_job.job_id;
   DELETE FROM ritc.identity_erasure WHERE job_id = old_job.job_id;
   DELETE FROM ritc.privacy_job WHERE job_id = old_job.job_id;
   jobs_purged := jobs_purged + 1;
  END IF;
 END LOOP;
 RETURN NEXT;
END $$;
