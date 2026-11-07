import type {Quantity} from './recovery-contracts.js';

export interface Rat { n:bigint; d:bigint }
export const zero:Rat = {n:0n,d:1n};

function reduced(numerator:bigint, denominator:bigint):Rat {
  let divisor = numerator < 0n ? -numerator : numerator;
  let remainder = denominator;
  while (remainder !== 0n) {
    const next = divisor % remainder;
    divisor = remainder;
    remainder = next;
  }
  return {n:numerator/divisor, d:denominator/divisor};
}

export const add = (a:Rat,b:Rat) => reduced(a.n*b.d + b.n*a.d, a.d*b.d);
export const sub = (a:Rat,b:Rat) => reduced(a.n*b.d - b.n*a.d, a.d*b.d);
export const cmp = (a:Rat,b:Rat) => a.n*b.d - b.n*a.d;
export const min = (a:Rat,b:Rat) => cmp(a,b) < 0n ? a : b;
export const wire = (a:Rat) => ({numerator:a.n.toString(), denominator:a.d.toString()});

// Base quantities are counts, grams and milliliters.
const units:Record<Quantity['unit'],{dimension:string;n:bigint;d:bigint}> = {
  count:      {dimension:'count',  n:1n,         d:1n},
  gram:       {dimension:'mass',   n:1n,         d:1n},
  kilogram:   {dimension:'mass',   n:1000n,      d:1n},
  ounce:      {dimension:'mass',   n:45359237n,  d:1600000n},
  pound:      {dimension:'mass',   n:45359237n,  d:100000n},
  milliliter: {dimension:'volume', n:1n,         d:1n},
  liter:      {dimension:'volume', n:1000n,      d:1n},
  fluidOunce: {dimension:'volume', n:473176473n, d:16000000n},
  cup:        {dimension:'volume', n:473176473n, d:2000000n},
};

export function amount(quantity:Quantity):Rat {
  const scale = units[quantity.unit];
  return reduced(BigInt(quantity.amount.numerator)*scale.n, BigInt(quantity.amount.denominator)*scale.d);
}
export function inUnit(base:Rat,unit:Quantity['unit']) {
  const scale = units[unit];
  return wire(reduced(base.n*scale.d, base.d*scale.n));
}
export const dimension = (quantity:Quantity) => units[quantity.unit].dimension;
