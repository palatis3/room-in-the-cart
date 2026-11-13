// Diagnostic fixture only; never included in canonical web/native products.
(() => {
  const doc=crypto.randomUUID(),events=[];let last='',truncated=false;
  const flags=()=>{
    const root=document.getElementById('app'),text=root?.innerText??'',item=root?.querySelector('#item')?.value??'';
    const main=root?.querySelector('main'),status=main?.querySelector('[role="status"]')?.textContent?.trim()??null;
    const buttons=Array.from(main?.querySelectorAll('button')??[]),named=label=>buttons.filter(b=>b.textContent.trim()===label);
    const queuePermissionControl=['Allow pending requests on this browser for up to 24 hours','Turn off and clear pending requests'].some(label=>named(label).length>0)||Array.from(main?.querySelectorAll('label')??[]).some(l=>l.textContent.trim()==='Save pending requests on this browser'&&l.querySelector('input[type="checkbox"]'));
    const ready=main?.getAttribute('aria-busy')==='false';
    return {ownA:text.includes('SAFARI_OWN_A_7d91'),ownB:text.includes('SAFARI_OWN_B_f51e'),queued:text.includes('SAFARI_QUEUE_OATS_4101'),draftA:item==='SAFARI_DRAFT_A_bf31',busy:root?.querySelector('main')?.getAttribute('aria-busy')==='true',waiting:status==='Waiting to send from this browser',received:status==='Received by the shopper.',missing:status==='A pending request is no longer stored on this browser. Check Your requests for its status.',ready,accessEnded:status==='Access has ended. Ask your household for a new invitation.',loadUnavailable:status==='Could not load your account. Refresh to try again.',refreshAvailable:named('Refresh').some(b=>!b.disabled),retryPresent:named('Retry').length>0,queuePermissionControl,contributorReady:ready&&!!main?.querySelector('#item')&&named('Review request').some(b=>!b.disabled)&&Array.from(main?.querySelectorAll('h2')??[]).some(h=>h.textContent.trim()==='Your requests'),statusEmpty:status===''};
  };
  function record(kind,persisted=false){if(events.length>=400){truncated=true;return;}events.push({kind,persisted,at:Math.round(performance.now()),...flags()});}
  // Registered before the app. A persisted pageshow must already contain no private DOM.
  addEventListener('pageshow',event=>record('pageshow',event.persisted));
  addEventListener('pagehide',event=>record('pagehide-before-app-listener',event.persisted));
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
    const receipt={version:2,doc,action,truncated,userAgent:navigator.userAgent,events:[...events],current:flags(),storage:await storage().catch(()=>({status:'inspection-failed'}))};
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
    button('Erase fixture pending storage',async()=>{await new Promise((resolve,reject)=>{const r=indexedDB.deleteDatabase('room-in-the-cart-own-outbox-v1');r.onsuccess=resolve;r.onerror=r.onblocked=()=>reject(Error('eviction-unavailable'));});await send('explicit-eviction');});
    const link=document.createElement('a');link.href='/neutral';link.textContent='Open neutral fixture page';aside.append(link);
    const status=document.createElement('p');status.id='fixture-evidence-status';status.setAttribute('role','status');aside.append(status);document.body.append(aside);
  });
})();
