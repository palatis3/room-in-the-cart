-- A standalone correction appends an observation to the exact reviewed lot.
ALTER TABLE ritc.pantry_event
  DROP CONSTRAINT pantry_event_check3,
  ADD COLUMN predecessor_observation_id uuid,
  ADD UNIQUE (household_id,lot_id,operation_id),
  ADD FOREIGN KEY (household_id,lot_id,predecessor_observation_id)
    REFERENCES ritc.pantry_event(household_id,lot_id,operation_id) ON DELETE CASCADE,
  ADD CONSTRAINT pantry_event_household_observation CHECK (
    (shop_id IS NOT NULL AND predecessor_observation_id IS NULL) OR
    (shop_id IS NULL AND kind='observe' AND (
      (lot_id=operation_id AND predecessor_observation_id IS NULL) OR
      (lot_id<>operation_id AND predecessor_observation_id IS NOT NULL AND predecessor_observation_id<>operation_id))));
