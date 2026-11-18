-- The retained before image follows the existing recovery graph's erasure policy.
ALTER TABLE ritc.meal_recovery_revision
 ADD COLUMN swap_before jsonb,
 ADD COLUMN swap_dependencies text CHECK (swap_dependencies ~ '^[0-9a-f]{64}$'),
 ADD CHECK ((swap_before IS NULL) = (swap_dependencies IS NULL)),
 ADD CHECK (swap_before IS NULL OR current_meal IS NOT NULL);

CREATE FUNCTION ritc.erase_swap_before() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF NEW.current_meal IS NULL THEN
   NEW.swap_before:=NULL;
   NEW.swap_dependencies:=NULL;
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ritc.erase_swap_before() FROM PUBLIC;
CREATE TRIGGER erase_swap_before BEFORE UPDATE OF current_meal ON ritc.meal_recovery_revision
 FOR EACH ROW EXECUTE FUNCTION ritc.erase_swap_before();
