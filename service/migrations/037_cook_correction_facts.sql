-- Generated sections are indexed within the already-reviewed immutable copy.
-- Older and custom-worded copies keep a NULL index and remain fully readable.
ALTER TABLE ritc.dated_cook_copy ADD COLUMN fact_index jsonb
 CHECK (fact_index IS NULL OR jsonb_typeof(fact_index)='object');
