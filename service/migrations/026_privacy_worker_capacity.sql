-- Separate worker-only probe. A job without remaining targets needs only
-- outcome capacity. An identical retry outcome needs no additional record.
CREATE FUNCTION ritc.privacy_worker_outcome_data(job ritc.privacy_job) RETURNS jsonb
LANGUAGE sql STABLE SET search_path=pg_catalog SET TimeZone='UTC' AS $$
 SELECT jsonb_build_object('appErasedAt',(job).app_erased_at,'providerErasedAt',(job).provider_erased_at,
  'completedAt',(job).completed_at,'receiptUntil',(job).receipt_until,'markerUntil',(job).marker_until)
$$;
REVOKE ALL ON FUNCTION ritc.privacy_worker_outcome_data(ritc.privacy_job) FROM PUBLIC,ritc_app,ritc_worker;

CREATE FUNCTION ritc.privacy_worker_journal_needs(j uuid,l uuid) RETURNS TABLE(target_remaining boolean,pending_needed boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 WITH leased AS (
  SELECT p AS job, EXISTS(SELECT 1 FROM ritc.privacy_target t WHERE t.job_id=j AND t.erased_at IS NULL) AS remaining
  FROM ritc.privacy_job p WHERE p.job_id=j AND p.lease_id=l AND p.state='processing'
   AND p.lease_until>clock_timestamp()
   AND NOT EXISTS(SELECT 1 FROM ritc.privacy_restore_job r WHERE r.job_id=j)
 )
 SELECT remaining,((job).app_erased_at IS NULL AND NOT remaining) OR NOT EXISTS(
  SELECT 1 FROM ritc.privacy_journal_outbox e WHERE e.job_id=j AND e.kind='source_pending'
   AND e.payload->'data'=ritc.privacy_worker_outcome_data(job)
 ) FROM leased
$$;
REVOKE ALL ON FUNCTION ritc.privacy_worker_journal_needs(uuid,uuid) FROM PUBLIC,ritc_app;
GRANT EXECUTE ON FUNCTION ritc.privacy_worker_journal_needs(uuid,uuid) TO ritc_worker;

CREATE OR REPLACE FUNCTION ritc.privacy_finish(j uuid,l uuid,provider_deleted boolean,failure text DEFAULT NULL) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE result boolean;v jsonb;kind text;
BEGIN
 IF EXISTS(SELECT 1 FROM ritc.privacy_restore_job WHERE job_id=j) THEN RETURN false; END IF;
 PERFORM 1 FROM ritc.privacy_journal_origin WHERE singleton AND NOT fenced FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'journal_unavailable'; END IF;
 IF provider_deleted AND EXISTS(SELECT 1 FROM ritc.privacy_journal_outbox e WHERE e.job_id=j AND NOT EXISTS(SELECT 1 FROM ritc.privacy_journal_ack a WHERE a.event_id=e.event_id)) THEN RAISE EXCEPTION 'journal_pending'; END IF;
 result=ritc.privacy_finish_v010(j,l,provider_deleted,failure);
 IF result THEN
  SELECT ritc.privacy_worker_outcome_data(p),CASE WHEN p.state='complete' THEN 'source_completed' ELSE 'source_pending' END
   INTO v,kind FROM ritc.privacy_job p WHERE p.job_id=j;
  IF kind='source_completed' OR NOT EXISTS(SELECT 1 FROM ritc.privacy_journal_outbox e WHERE e.job_id=j
   AND e.kind='source_pending' AND e.payload->'data'=v) THEN
   PERFORM ritc.privacy_journal_emit(j,kind,v);
  END IF;
 END IF;
 RETURN result;
END $$;
