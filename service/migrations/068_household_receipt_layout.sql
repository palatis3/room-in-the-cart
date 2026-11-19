-- The canonical receipt key keeps the coordinate system that first supplied its lines.
-- Older key mappings cannot establish which file supplied those coordinates.
ALTER TABLE ritc.receipt_source_key ADD COLUMN original_layout_digest text,
 ADD CHECK (original_layout_digest IS NULL OR (source_id=receipt_id AND original_layout_digest ~ '^[0-9a-f]{64}$'));
