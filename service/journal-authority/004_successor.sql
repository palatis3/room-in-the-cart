BEGIN;
CREATE TABLE ritc_checkpoint.successor (
 predecessor uuid PRIMARY KEY REFERENCES ritc_checkpoint.recovery_seal(lineage),
 successor uuid UNIQUE NOT NULL REFERENCES ritc_checkpoint.origin(lineage),
 proof jsonb NOT NULL,
 CHECK(predecessor<>successor)
);
REVOKE ALL ON ritc_checkpoint.successor FROM PUBLIC,ritc_checkpoint_runtime,ritc_record_runtime;

CREATE FUNCTION ritc_checkpoint.immutable_successor() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 RAISE EXCEPTION 'immutable journal successor';
END $$;
REVOKE ALL ON FUNCTION ritc_checkpoint.immutable_successor() FROM PUBLIC;
CREATE TRIGGER immutable_successor BEFORE UPDATE OR DELETE ON ritc_checkpoint.successor
 FOR EACH ROW EXECUTE FUNCTION ritc_checkpoint.immutable_successor();
COMMIT;
