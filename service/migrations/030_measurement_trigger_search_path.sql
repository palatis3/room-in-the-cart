-- Resolve built-ins consistently in the measurement triggers regardless of the caller's search path.
ALTER FUNCTION ritc.measurement_consent_immutable() SET search_path=pg_catalog;
ALTER FUNCTION ritc.measurement_feedback_eligible() SET search_path=pg_catalog;
