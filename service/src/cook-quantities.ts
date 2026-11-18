import { invalid } from './errors.js';
import { amount, cmp, dimension, inUnit, sub, type Rat } from './physical-quantity.js';
import { usableQuantitySchema, type Quantity } from './recovery-contracts.js';

// Quantities cross the JSON boundary only after exact rational arithmetic.
export function counted(base:Rat, unit:Quantity['unit']):Quantity {
  const {numerator,denominator}=inUnit(base,unit);
  const originalLiteral=denominator==='1'?numerator:numerator+'/'+denominator;
  const value=usableQuantitySchema.safeParse({unit,amount:{numerator:Number(numerator),denominator:Number(denominator)},originalLiteral});
  if(!value.success) throw invalid();
  return value.data;
}
export function remainingPromise(quantity:Quantity|null,fulfilled:Quantity[]|null):Quantity|null {
  if(!quantity || !fulfilled) return quantity;
  let left=amount(quantity);
  for(const part of fulfilled){
    if(dimension(quantity)!==dimension(part) || cmp(left,amount(part))<0n) throw invalid();
    left=sub(left,amount(part));
  }
  return left.n===0n?null:counted(left,quantity.unit);
}
export const activeFulfillment=(reservation:string)=>`(SELECT jsonb_agg(f.quantity) FROM ritc.cook_fulfillment f
  JOIN ritc.shared_cook c ON (c.household_id,c.operation_id)=(f.household_id,f.cook_id) AND c.undone_by IS NULL
  WHERE f.household_id=$1 AND f.reservation_id=${reservation})`;
