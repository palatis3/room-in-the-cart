import {test} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {eligibleMeasurementWeek,measurementBenefit,measurementFeedbackSchema,measurementConsentSchema,MEASUREMENT_NOTICE_VERSION} from '../dist/measurement.js';
test('eligible week is the ISO UTC closure week, including year boundaries',()=>{
 for(const [date,week] of [['2026-11-03T20:00:00Z','2026-W45'],['2027-01-01T02:00:00Z','2026-W53'],['2027-01-04T00:00:00Z','2027-W01'],['2026-11-08T23:59:59Z','2026-W45']])assert.equal(eligibleMeasurementWeek(new Date(date)),week);
});
test('tie, late, known, wrong and unchanged outcomes never produce benefit',()=>{
 for(const outcome of ['acted','unchanged','late','unknown','already_knew','wrong'])assert.equal(measurementBenefit({outcome,baseline:'list',comparison:'same'}),0);
 for(const outcome of ['late','already_knew','unchanged','wrong'])assert.equal(measurementBenefit({outcome,baseline:'retailer',comparison:'different'}),0);
 assert.equal(measurementBenefit({outcome:'acted',baseline:'list',comparison:'different'}),null);
});
test('measurement allowlist rejects grocery data, client identity/week and billing claims',()=>{
 const value={consentId:randomUUID(),noticeVersion:MEASUREMENT_NOTICE_VERSION,outcome:'acted',baseline:'list',comparison:'different'};
 assert.equal(measurementFeedbackSchema.safeParse(value).success,true);
 for(const extra of [{groceryText:'private'},{householdId:randomUUID()},{eligibleWeek:'2026-W45'},{amountMinor:4999},{transactionID:'123'},{membership:true},{memberName:'Private'}])assert.equal(measurementFeedbackSchema.safeParse({...value,...extra}).success,false);
 assert.equal(measurementConsentSchema.safeParse({noticeVersion:'old'}).success,false);
 assert.equal(measurementConsentSchema.safeParse({noticeVersion:MEASUREMENT_NOTICE_VERSION,consent:true}).success,false);
});
