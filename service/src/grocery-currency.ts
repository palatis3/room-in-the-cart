import { z } from 'zod';
import type { GroceryCurrency } from '../../shared/contracts/service-v1.js';
import { ServiceError } from './errors.js';

export const groceryCurrencySchema = z.enum(['USD', 'MXN']);

export function requireMatchingCurrency(currency: GroceryCurrency, expected: GroceryCurrency) {
  if (currency !== expected) {
    throw new ServiceError(422, 'currency_mismatch', 'Enter amounts in the currency of this shop or budget period.');
  }
}

export function requireSupportedCurrency(scope: { supportsMXN?: boolean }, currency: GroceryCurrency) {
  if (currency === 'MXN' && !scope.supportsMXN) {
    throw new ServiceError(409, 'currency_unsupported', 'Update Room in the Cart to review Mexican peso amounts.');
  }
}
