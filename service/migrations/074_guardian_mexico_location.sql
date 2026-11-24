ALTER TABLE ritc.guardian_enrollment
  DROP CONSTRAINT guardian_enrollment_child_location_check,
  ADD CONSTRAINT guardian_enrollment_child_location_check
    CHECK (child_location ~ '^US(-[A-Z]{2})?$' OR child_location = 'MX');
