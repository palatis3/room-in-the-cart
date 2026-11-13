import assert from 'node:assert/strict';

export async function waitForIdle(root) {
 const deadline=Date.now()+3000;
 while(root.querySelector('main')?.getAttribute('aria-busy')==='true'){
  assert.ok(Date.now()<deadline,'the page did not finish its action');
  await new Promise(resolve=>setTimeout(resolve,5));
 }
}
