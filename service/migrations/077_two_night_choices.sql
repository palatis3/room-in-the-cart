-- A two-dinner confirmation has one operation receipt and one provenance row per occurrence.
ALTER TABLE ritc.tonight_choice DROP CONSTRAINT tonight_choice_household_id_operation_id_key;
CREATE INDEX tonight_choice_operation ON ritc.tonight_choice(household_id, operation_id);
