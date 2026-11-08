// Diagnostic fixture only; never included in canonical web/native products.
(() => {
  const doc=crypto.randomUUID(),events=[];let last='',truncated=false;
  const flags=()=>{
    const root=document.getElementById('app'),text=root?.textContent??'',main=root?.querySelector('main');
    const status=main?.querySelector('[role="status"]')?.textContent?.trim()??null;
    const buttons=Array.from(main?.querySelectorAll('button')??[]),named=label=>buttons.filter(b=>b.textContent.trim()===label);
    const correction=main?.querySelector('#correction'),ready=main?.getAttribute('aria-busy')==='false';
    const displayDate=value=>new Intl.DateTimeFormat('en-US',{dateStyle:'full',timeStyle:'short'}).format(new Date(value));
    const paragraphs=Array.from(main?.querySelectorAll('p')??[]).map(p=>p.textContent.trim());
    const controls=['Send proposal','Check received suggestions','Show older suggestions','Retry original suggestion','Check suggestion status','Write another suggestion','Review current instructions'];
    return {household:text.includes('SAFARI_EDITOR_HOUSEHOLD_783a'),shop:text.includes('SAFARI_EDITOR_SHOP_249d'),instruction:text.includes('SAFARI_COOK_WRAP_b038'),amount:text.includes('6 wraps'),action:text.includes('SAFARI_SAVE_TWO_LUNCHES_18ac'),suggestion:text.includes('SAFARI_RECEIVED_SUGGESTION_e134'),draft:correction?.value==='SAFARI_UNSENT_CORRECTION_b7e2',draftPresent:!!correction&&correction.value.length>0,editorControlsPresent:!!correction||controls.some(x=>named(x).length>0),editorReady:ready&&!!correction&&named('Send proposal').some(b=>!b.disabled)&&named('Check received suggestions').some(b=>!b.disabled),cookHeadingPresent:Array.from(main?.querySelectorAll('h1')??[]).some(x=>x.textContent.trim()==='Current instructions'),datedRevision:paragraphs.includes('As of: '+displayDate('2026-11-08T12:00:00Z'))&&paragraphs.includes('Revision: 7')&&paragraphs.includes('Expires: '+displayDate('2099-01-01T00:00:00Z')),forbiddenBudget:text.includes('FORBIDDEN_BUDGET_d539'),forbiddenOtherShop:text.includes('FORBIDDEN_OTHER_SHOP_6e30'),contributorControlsPresent:!!main?.querySelector('#item')||named('Review request').length>0,busy:main?.getAttribute('aria-busy')==='true',ready,accessEnded:status==='Access has ended. Ask your household for a new invitation.',loadUnavailable:status==='Could not load your account. Refresh to try again.',refreshAvailable:named('Refresh').some(b=>!b.disabled),statusEmpty:status===''};
  };
  function record(kind,persisted=false){if(events.length>=400){truncated=true;return;}events.push({kind,persisted,visibility:document.visibilityState,at:Math.round(performance.now()),...flags()});}
  // Registered before the app. A persisted pageshow must already contain no private DOM.
  addEventListener('pageshow',event=>record('pageshow',event.persisted));
  addEventListener('pagehide',event=>record('pagehide-before-app-listener',event.persisted));
  document.addEventListener('visibilitychange',()=>{
    record('visibility-before-app-listener');
    // A new task follows native event listeners; a microtask may run between them.
    if(document.visibilityState==='visible')setTimeout(()=>record('visibility-after-task'),0);
  });
  const digest=async value=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(value))),x=>x.toString(16).padStart(2,'0')).join('');
  async function storage(){
    if(typeof indexedDB?.databases!=='function')return {status:'inspection-unavailable'};
    if(!(await indexedDB.databases()).some(x=>x.name==='room-in-the-cart-own-outbox-v1'))return {status:'absent',count:0,commands:[]};
    const db=await new Promise((resolve,reject)=>{const r=indexedDB.open('room-in-the-cart-own-outbox-v1',1);r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(Error('storage-open'));r.onupgradeneeded=()=>{r.transaction.abort();reject(Error('database-disappeared'));};});
    try {
      const rows=await new Promise((resolve,reject)=>{let rows;const tx=db.transaction('pending','readonly'),r=tx.objectStore('pending').getAll();r.onsuccess=()=>{rows=r.result;};tx.oncomplete=()=>resolve(rows);tx.onabort=tx.onerror=()=>reject(Error('storage-read'));});
      if(rows.length>20)return {status:'unexpected-row-count'};
      const commands=await Promise.all(rows.map(async r=>({digest:await digest(JSON.stringify(r.command))})));
      return {status:'read',count:rows.length,commands};
    } finally {db.close();}
  }
  async function send(action){
    const receipt={version:5,doc,action,truncated,visibility:document.visibilityState,userAgent:navigator.userAgent,events:[...events],current:flags(),storage:await storage().catch(()=>({status:'inspection-failed'}))};
    const response=await fetch('/__fixture/observation',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(receipt),cache:'no-store'});
    if(!response.ok)throw Error('observation-rejected');
    document.getElementById('fixture-evidence-status').textContent='Fixture observation recorded';
  }
  document.addEventListener('DOMContentLoaded',()=>{
    const root=document.getElementById('app');
    if(root)new MutationObserver(()=>{const now=JSON.stringify(flags());if(now!==last){last=now;record('render');}}).observe(root,{childList:true,subtree:true,characterData:true});
    const aside=document.createElement('aside');aside.setAttribute('aria-label','Synthetic Safari fixture tools');
    const title=document.createElement('p');title.textContent='Synthetic fixture tools — outside the product';aside.append(title);
    const button=(title,action)=>{const b=document.createElement('button');b.type='button';b.textContent=title;b.addEventListener('click',()=>{b.disabled=true;Promise.resolve().then(action).catch(()=>{status.textContent='Fixture observation unavailable';}).finally(()=>{b.disabled=false;});});aside.append(b);};
    button('Record fixture observation',()=>send('observe'));
    const status=document.createElement('p');status.id='fixture-evidence-status';status.setAttribute('role','status');aside.append(status);document.body.append(aside);
  });
})();
