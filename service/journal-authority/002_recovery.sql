BEGIN;
CREATE TABLE ritc_checkpoint.recovery_seal (
 lineage uuid PRIMARY KEY REFERENCES ritc_checkpoint.origin,
 proof jsonb NOT NULL,
 tail_objects jsonb NOT NULL
);
REVOKE ALL ON ritc_checkpoint.recovery_seal FROM PUBLIC,ritc_checkpoint_runtime,ritc_record_runtime;

CREATE FUNCTION ritc_checkpoint.guard_origin_recovery() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE old_mode text := OLD.head->>'mode'; new_mode text := NEW.head->>'mode';
BEGIN
 IF NEW.lineage IS DISTINCT FROM OLD.lineage OR NEW.scope_digest IS DISTINCT FROM OLD.scope_digest OR old_mode='sealed' THEN
  RAISE EXCEPTION 'immutable checkpoint origin';
 END IF;
 IF old_mode='recovery' OR new_mode IN ('recovery','sealed') THEN
  IF current_user<>session_user OR current_user<>(SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid=TG_RELID) THEN
   RAISE EXCEPTION 'checkpoint recovery requires the operator owner' USING ERRCODE='42501';
  END IF;
  IF new_mode='recovery' AND old_mode IN ('active','pending','blocked') AND NEW.claim IS NOT DISTINCT FROM OLD.claim
   AND NEW.pending IS NOT DISTINCT FROM OLD.pending AND NEW.head = OLD.head || jsonb_build_object(
    'head',(OLD.head->'head')||'{"fenced":true}'::jsonb,'mode','recovery','generation',(OLD.head->>'generation')::bigint+1,
    'authorityRevision',(OLD.head->>'authorityRevision')::bigint+1) THEN RETURN NEW; END IF;
  IF old_mode='recovery' AND new_mode='sealed' AND NEW.claim IS NULL AND NEW.pending IS NULL
   AND NEW.head->>'generation'=OLD.head->>'generation' AND NEW.head->'head'->>'fenced'='true'
   AND EXISTS(SELECT 1 FROM ritc_checkpoint.recovery_seal WHERE lineage=NEW.lineage) THEN RETURN NEW; END IF;
  RAISE EXCEPTION 'invalid checkpoint recovery transition';
 END IF;
 IF NEW.head->'head'->>'fenced' IS DISTINCT FROM 'false' OR NEW.head->>'generation' IS DISTINCT FROM OLD.head->>'generation' THEN
  RAISE EXCEPTION 'checkpoint fence is irreversible';
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ritc_checkpoint.guard_origin_recovery() FROM PUBLIC;
CREATE TRIGGER guard_origin_recovery BEFORE UPDATE ON ritc_checkpoint.origin
 FOR EACH ROW EXECUTE FUNCTION ritc_checkpoint.guard_origin_recovery();
COMMIT;
