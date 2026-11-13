import assert from 'node:assert/strict';
const flags=['ownA','ownB','queued','draftA','busy','waiting','received','missing','ready','accessEnded','loadUnavailable','refreshAvailable','retryPresent','queuePermissionControl','contributorReady','statusEmpty'];
const exact=(o,keys)=>{assert(o&&typeof o==='object'&&!Array.isArray(o));assert.deepEqual(Object.keys(o).sort(),[...keys].sort());};
const checkFlags=o=>{for(const k of flags)assert.equal(typeof o[k],'boolean');};
export function validateObservation(o){
 exact(o,['version','doc','action','truncated','userAgent','events','current','storage']);assert.equal(o.version,2);assert.equal(typeof o.truncated,'boolean');assert.match(o.doc,/^[0-9a-f-]{36}$/);assert(['observe','explicit-eviction'].includes(o.action));
 assert.equal(typeof o.userAgent,'string');assert(o.userAgent.length<=512);assert(Array.isArray(o.events)&&o.events.length<=400);
 exact(o.current,flags);checkFlags(o.current);
 for(const e of o.events){exact(e,['kind','persisted','at',...flags]);assert(['pageshow','pagehide-before-app-listener','render'].includes(e.kind));assert.equal(typeof e.persisted,'boolean');assert(Number.isSafeInteger(e.at)&&e.at>=0);checkFlags(e);}
 const s=o.storage;assert(['read','absent','inspection-unavailable','unexpected-row-count','inspection-failed'].includes(s.status));
 if(['read','absent'].includes(s.status)){exact(s,['status','count','commands']);assert(Number.isSafeInteger(s.count)&&s.count>=0&&s.count<=20);assert(Array.isArray(s.commands)&&s.commands.length===s.count);for(const c of s.commands){exact(c,['digest']);assert.match(c.digest,/^[0-9a-f]{64}$/);}if(s.status==='absent')assert.equal(s.count,0);}
 else exact(s,['status']);
 return o;
}
