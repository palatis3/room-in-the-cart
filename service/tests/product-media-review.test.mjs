import test from 'node:test';
import assert from 'node:assert/strict';
import {reviewChoice,reviewFrame} from '../scripts/review-product-media.mjs';
test('staffed media review renders RGB pixels without interpreting untrusted product text as terminal instructions',()=>{
  const row={width:8,height:8,pixels:Buffer.alloc(8*8*3,120),description:'Bottle\x1b[2J\r\n\u202etext'};
  const frame=reviewFrame(row,80,30);
  assert(frame.startsWith('Bottle [2J   text\n'));
  assert(frame.includes('\x1b[38;2;120;120;120m'));
  assert.equal((frame.match(/▀/g)??[]).length,32);
  assert.throws(()=>reviewFrame({...row,pixels:Buffer.alloc(2)},80,30));
});

for(const reason of ['expiry','withdrawal','unavailable']){
  test('operator screen clears a waiting crop on '+reason,async()=>{
    let shown=false,cleared=false;
    const choice=await reviewChoice({expiresAt:Date.now()+(reason==='expiry'?30:1000),
      show:()=>{shown=true;},clear:()=>{cleared=true;},
      ask:signal=>new Promise((_,reject)=>signal.addEventListener('abort',()=>reject(Error('closed')),{once:true})),
      stillPending:async()=>{if(reason==='unavailable')throw Error('offline');return reason==='expiry';},pollMs:5});
    assert.equal(choice,undefined);assert(shown&&cleared);
  });
}
