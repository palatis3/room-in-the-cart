import assert from 'node:assert/strict';
import test from 'node:test';
import {reviewSharedWording} from '../dist/shared-content-filter.js';

test('screen English and Spanish directed abuse without matching grocery names',()=>{
  for(const text of ['I will hurt you','GＯ kill yourself','vete a la mierda','Te voy a hacer daño','Envíame fotos íntimas']) {
    assert.throws(()=>reviewSharedWording(text),error=>error.code==='content_review_required'&&!error.recovery.includes(text));
  }
  for(const text of ['Dave’s Killer Bread','Jerk chicken','Spotted dick pudding','Bloody Mary mix','Pasta alla puttanesca','Jamón de Pata Negra','salsa madre','Mata el hambre con fruta','Use a knife to cut the squash']) {
    assert.doesNotThrow(()=>reviewSharedWording(text));
  }
  assert.throws(()=>reviewSharedWording('I will','hurt you'));
});
