ALTER TABLE ritc.shop
  ADD COLUMN currency text NOT NULL DEFAULT 'USD',
  ADD CONSTRAINT shop_currency_matches_quote CHECK (
    currency IN ('USD','MXN') AND currency=COALESCE(quote->>'currency','USD')
  ),
  ADD CONSTRAINT shop_currency_identity UNIQUE (household_id,shop_id,currency);

CREATE TRIGGER shop_currency_immutable
  BEFORE UPDATE OF currency ON ritc.shop
  FOR EACH ROW WHEN (OLD.currency IS DISTINCT FROM NEW.currency)
  EXECUTE FUNCTION ritc.immutable_row();

ALTER TABLE ritc.financial_entry
  ADD COLUMN currency text NOT NULL DEFAULT 'USD',
  ADD CONSTRAINT financial_entry_shop_currency FOREIGN KEY (household_id,shop_id,currency)
    REFERENCES ritc.shop (household_id,shop_id,currency);

ALTER TABLE ritc.receipt_source_key
  ADD COLUMN currency text NOT NULL DEFAULT 'USD' CHECK (currency IN ('USD','MXN'));
