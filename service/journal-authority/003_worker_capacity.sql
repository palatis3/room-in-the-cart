BEGIN;
CREATE TABLE ritc_checkpoint.worker_allowance (
 lineage uuid NOT NULL REFERENCES ritc_checkpoint.origin,
 job_id uuid NOT NULL,
 event_kind text NOT NULL,
 bytes integer NOT NULL,
 PRIMARY KEY(lineage,job_id,event_kind),
 CHECK((event_kind='target_erased' AND bytes=1050624) OR
  (event_kind IN ('source_pending','source_completed') AND bytes=4096))
);
REVOKE ALL ON ritc_checkpoint.worker_allowance FROM PUBLIC,ritc_record_runtime;
GRANT SELECT,INSERT,DELETE ON ritc_checkpoint.worker_allowance TO ritc_checkpoint_runtime;
COMMIT;
