-- The original shop snapshot and subsequently accepted step receipts are immutable.
-- Keep references, so erasure/retirement of the underlying evidence takes effect.
ALTER TABLE ritc.shared_repeat_week
  ADD COLUMN basket_revision integer CHECK (basket_revision > 0),
  ADD COLUMN store_revision integer CHECK (store_revision > 0 AND store_revision <= basket_revision),
  ADD FOREIGN KEY (household_id,shop_id,basket_revision) REFERENCES ritc.shop_snapshot(household_id,shop_id,revision);
