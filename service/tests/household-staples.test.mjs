import test from 'node:test';
import assert from 'node:assert/strict';
import {comparablePurchaseInterval} from '../dist/household-staples.js';

const quantity=(n,unit='count')=>({amount:{numerator:n,denominator:1},unit,originalLiteral:String(n)});
const record=(day,n,unit)=>({day:'2026-03-'+day,quantity:quantity(n,unit)});

test('three comparable purchase days cross the civil DST boundary and total same-day fragments once',()=>{
 const rows=[record('01',1000,'gram'),record('07',1,'kilogram'),record('15',600,'gram'),record('15',400,'gram')];
 assert.deepEqual(comparablePurchaseInterval(rows),{purchaseDays:3,intervalDays:7,dueDay:'2026-03-22'});
 assert.equal(comparablePurchaseInterval(rows.slice(2)),null);
});

test('a changed pack, incompatible amount, or superseded source cannot bridge an interval',()=>{
 const rows=[record('01',1),record('07',1),record('14',2),record('21',1)];
 assert.equal(comparablePurchaseInterval(rows),null);
 assert.equal(comparablePurchaseInterval([record('01',1,'liter'),record('08',1,'kilogram'),record('15',1,'liter')]),null);
 assert.equal(comparablePurchaseInterval([record('01',1),record('08',1),record('15',1),{day:'2026-03-21',quantity:undefined}]),null);
});
