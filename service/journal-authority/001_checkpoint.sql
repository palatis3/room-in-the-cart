-- Apply only to the independent journal database as its schema owner. The two
-- preprovisioned groups are distinct from the app, worker, and source observer.
BEGIN;
CREATE SCHEMA ritc_checkpoint;
CREATE SCHEMA ritc_records;
REVOKE ALL ON SCHEMA ritc_checkpoint,ritc_records FROM PUBLIC;

CREATE TABLE ritc_checkpoint.origin (
 lineage uuid PRIMARY KEY,
 scope_digest text UNIQUE NOT NULL CHECK(scope_digest ~ '^[0-9a-f]{64}$'),
 head jsonb NOT NULL,
 claim jsonb,
 pending jsonb
);
CREATE TABLE ritc_checkpoint.admission (
 lineage uuid NOT NULL REFERENCES ritc_checkpoint.origin,
 operation_id text NOT NULL CHECK(operation_id ~ '^[0-9a-f]{64}$'),
 event_id uuid NOT NULL,
 job_id uuid NOT NULL,
 transition text NOT NULL CHECK(transition IN ('intent','commit','rollback')),
 event_kind text NOT NULL CHECK(event_kind IN ('acceptance','target_erased','source_pending','source_completed')),
 sequence integer NOT NULL CHECK(sequence BETWEEN 1 AND 10000),
 ticket jsonb NOT NULL,
 receipt jsonb NOT NULL,
 PRIMARY KEY(lineage,operation_id),
 UNIQUE(lineage,event_id,transition),
 UNIQUE(lineage,sequence)
);
CREATE UNIQUE INDEX original_acceptance ON ritc_checkpoint.admission(lineage,job_id)
 WHERE event_kind='acceptance' AND transition='commit';

CREATE TABLE ritc_records.store (
 singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
 identity text NOT NULL CHECK(length(identity) BETWEEN 1 AND 300)
);
CREATE TABLE ritc_records.object (
 object_key text PRIMARY KEY CHECK(object_key ~ '^[0-9a-f]{64}/[1-9][0-9]{0,4}/[0-9a-f]{64}$'),
 version uuid NOT NULL,
 record_hash text NOT NULL CHECK(record_hash ~ '^[0-9a-f]{64}$'),
 content bytea NOT NULL CHECK(octet_length(content) BETWEEN 1 AND 33554432)
);

REVOKE ALL ON ALL TABLES IN SCHEMA ritc_checkpoint,ritc_records FROM PUBLIC;
GRANT USAGE ON SCHEMA ritc_checkpoint,ritc_records TO ritc_checkpoint_runtime;
GRANT SELECT ON ritc_checkpoint.origin TO ritc_checkpoint_runtime;
GRANT UPDATE(head,claim,pending) ON ritc_checkpoint.origin TO ritc_checkpoint_runtime;
GRANT SELECT,INSERT ON ritc_checkpoint.admission TO ritc_checkpoint_runtime;
GRANT SELECT ON ritc_records.store,ritc_records.object TO ritc_checkpoint_runtime;
GRANT USAGE ON SCHEMA ritc_records TO ritc_record_runtime;
GRANT SELECT ON ritc_records.store TO ritc_record_runtime;
GRANT SELECT,INSERT ON ritc_records.object TO ritc_record_runtime;
COMMIT;
