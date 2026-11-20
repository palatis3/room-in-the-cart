import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {tripConfiguration} from '../dist/trip-substitutions.js';

const ok=res=>{assert.equal(res.status,200,JSON.stringify(res.data));return res.data;};
const code=(res,expected)=>assert.equal(res.data.error?.code,expected,JSON.stringify(res.data));
const until=()=>new Date(Date.now()+3600000).toISOString();

export function tripCoordinationTests({fixture,admin,repo}) {
  const run=(title,body)=>test('trip coordination '+title,async t=>{
    Object.assign(repo.options,{tripSubstitutions:true,sharedPicking:true});
    t.after(()=>{delete repo.options.tripSubstitutions;delete repo.options.sharedPicking;});
    const f=await fixture({otherAdult:true}),path='/shops/'+f.shopId+'/shared-picking';
    const read=(name='Mia')=>f.http(name,'GET',path);
    const grant=(overrides={})=>({clientKey:randomUUID(),expectedPermissionId:null,authorityEpoch:1,shopRevision:1,
      recipientId:f.actors.Alex.id,lineIds:[f.lineId],expiresAt:until(),...overrides});
    const manage=(data,name='Mia')=>f.http(name,'POST',path+'/permission',data);
    const act=(name,data)=>f.http(name,'POST',path+'/operations',data);
    const op=(name,g,overrides={})=>({operationId:randomUUID(),actorId:f.actors[name].id,deviceId:f.actors[name].deviceId,
      rowId:f.lineId,permissionId:g.permissionId,expectedRevision:g.rows[0].revision,action:'pick',packs:1,...overrides});
    await body({...f,path,read,grant,manage,act,op});
  });
  run('unanswered adults may add or link only the original pack, including previously reviewed and linked lines',async f=>{
    const request=(await f.send('Alex',{originalItem:f.line.originalItem})).request;
    const alternative={...f.line,lineId:randomUUID(),originalItem:'Different pack'};
    const add={choice:'add',line:alternative},link={choice:'link',lineId:f.lineId};
    const apply=preview=>f.command('Mia','request.apply',{requestId:request.requestId,previewId:preview.previewId,acceptOverage:true,acceptUnknown:false},
      {authorityEpoch:1,shopRevision:1,requestRevision:request.revision});
    code(await f.preview(request,add),'substitution_changed');
    ok(await f.preview(request,{choice:'add',line:{...alternative,originalItem:request.originalItem}}));

    // Previously reviewed work from a flag-off deployment must be checked again during apply.
    repo.options.tripSubstitutions=false;
    const previous=ok(await f.preview(request,add));
    repo.options.tripSubstitutions=true;
    code(await apply(previous),'substitution_changed');

    const other=(await f.send('Alex',{originalItem:'Another request'})).request;
    code(await f.preview(other,link),'substitution_changed');
    const accepted=ok(await apply(ok(await f.preview(request,link))));
    const patch=()=>f.command('Mia','shop.patch',{quote:f.quote,lines:[{...f.line,originalItem:alternative.originalItem}]},
      {authorityEpoch:1,shopRevision:accepted.shopRevision});
    code(await patch(),'substitution_changed');
    const child=(await f.send('Sam',{originalItem:'A child request'})).request;
    ok(await f.preview(child,add,'Mia',{authorityEpoch:1,shopRevision:accepted.shopRevision,requestRevision:child.revision}));
    repo.options.tripSubstitutions=false;
    ok(await patch());
  });
  run('adult answers are scoped, moderated and rechecked at preview and apply',async f=>{
    const r=(await f.send('Alex')).request,path='/shops/'+f.shopId+'/requests/'+r.requestId+'/substitution';
    const write=(actor,x)=>f.http(actor,'POST',path,x),read=actor=>f.http(actor,'GET',path);
    const answer=(choice,revision,extra={})=>({clientKey:randomUUID(),expectedRevision:revision,authorityEpoch:1,requestRevision:1,choice,...extra});
    assert.equal(ok(await read('Mia')).choice,'undecided');
    for(const actor of ['Sam','Lee'])assert.equal((await read(actor)).status,404);
    assert.equal((await write('Mia',answer('exact',0))).status,404);
    code(await write('Alex',answer('alternative',0,{alternative:'go kill yourself'})),'content_review_required');
    const named=answer('alternative',0,{alternative:'Named oat pack 1 L'});
    const received=ok(await write('Alex',named));assert.deepEqual(ok(await write('Alex',named)),received);
    code(await write('Alex',{...named,alternative:'Another pack'}),'key_reused');
    const added={choice:'add',line:{...f.line,lineId:randomUUID(),originalItem:named.alternative}};
    const p=ok(await f.preview(r,added));
    const apply=preview=>f.command('Mia','request.apply',{requestId:r.requestId,previewId:preview.previewId,acceptOverage:true,acceptUnknown:false},
      {authorityEpoch:1,shopRevision:1,requestRevision:r.revision});
    ok(await write('Alex',answer('exact',1)));
    code(await apply(p),'substitution_changed');
    code(await f.preview(r,added),'substitution_changed');
    ok(await write('Alex',answer('skip',2)));
    ok(await f.preview(r));
    code(await f.preview(r,{choice:'link',lineId:f.lineId}),'substitution_changed');
    ok(await write('Alex',answer('alternative',3,{alternative:named.alternative})));
    code(await apply(p),'stale_preview');
    const receipt=ok(await apply(ok(await f.preview(r,added))));
    assert.equal(receipt.disposition,'added');
    assert.equal(ok(await read('Mia')).alternative,named.alternative);
    code(await f.command('Mia','shop.patch',{quote:f.quote,lines:[f.line,{...added.line,originalItem:'Unreviewed pack'}]},
      {authorityEpoch:1,shopRevision:receipt.shopRevision}),'substitution_changed');
    const list=ok(await f.read());
    assert(!list.availableRows.some(row=>row.id===added.line.lineId));
    assert.equal((await f.manage(f.grant({shopRevision:receipt.shopRevision,lineIds:[added.line.lineId]}))).status,404);
    const report=ok(await f.http('Mia','POST','/moderation/actions',{clientKey:randomUUID(),action:'report',reason:'other',
      source:{kind:'substitution',id:r.requestId,revision:4,field:'alternative'}}));
    assert.equal(report.status,'received');
    await admin.query("SELECT ritc.moderation_resolve($1,'remove')",[report.receiptId]);
    assert.equal(ok(await read('Mia')).alternative,null);
  });
  run('request edits and shopper reassignment invalidate decisions and pending work',async f=>{
    const r=(await f.send('Alex')).request,path='/shops/'+f.shopId+'/requests/'+r.requestId+'/substitution';
    const answer={clientKey:randomUUID(),authorityEpoch:1,requestRevision:1,expectedRevision:0,choice:'alternative',alternative:'A named pack'};
    ok(await f.http('Alex','POST',path,answer));
    ok(await f.command('Alex','request.edit',{requestId:r.requestId,originalItem:'Another grocery',ownQuantity:'one pack'},
      {authorityEpoch:1,shopRevision:1,requestRevision:1}));
    const changed=ok(await f.http('Mia','GET',path));
    assert.equal(changed.choice,'undecided');assert.equal(changed.originalItem,'Another grocery');
    const oldPack={choice:'add',line:{...f.line,lineId:randomUUID(),originalItem:answer.alternative}};
    const edited={...r,revision:changed.requestRevision};
    code(await f.preview(edited,oldPack),'substitution_changed');
    ok(await f.preview(edited,{choice:'add',line:{...oldPack.line,originalItem:changed.originalItem}}));
    code(await f.http('Alex','POST',path,answer),'stale_base');
    ok(await f.http('Alex','POST',path,{...answer,expectedRevision:changed.revision,requestRevision:changed.requestRevision,clientKey:randomUUID()}));
    const g=ok(await f.manage(f.grant())),pending=f.op('Alex',g);
    await admin.query('UPDATE ritc.shop SET shopper_id=$3,authority_epoch=authority_epoch+1,revision=revision+1 WHERE household_id=$1 AND shop_id=$2',[f.h,f.shopId,f.actors.Lee.id]);
    assert.equal(ok(await f.http('Lee','GET',path)).choice,'undecided');
    const afterTransfer={authorityEpoch:2,shopRevision:2,requestRevision:edited.revision};
    code(await f.preview(edited,oldPack,'Lee',afterTransfer),'substitution_changed');
    ok(await f.preview(edited,{choice:'add',line:{...oldPack.line,originalItem:changed.originalItem}},'Lee',afterTransfer));
    assert.equal((await f.http('Mia','GET',path)).status,404);
    assert.equal((await f.act('Alex',pending)).status,404);
    assert.equal((await f.read('Mia')).status,404);
  });
  run('a replacement shopper cannot rename an accepted row using the previous shopper’s approval',async f=>{
    const r=(await f.send('Alex',{originalItem:f.line.originalItem})).request;
    const path='/shops/'+f.shopId+'/requests/'+r.requestId+'/substitution';
    ok(await f.http('Alex','POST',path,{clientKey:randomUUID(),requestRevision:1,authorityEpoch:1,expectedRevision:0,
      choice:'alternative',alternative:'Approved for the original shopper'}));
    const p=ok(await f.preview(r,{choice:'link',lineId:f.lineId}));
    const accepted=ok(await f.command('Mia','request.apply',{requestId:r.requestId,previewId:p.previewId,acceptOverage:false,acceptUnknown:false},
      {authorityEpoch:1,shopRevision:1,requestRevision:r.revision}));
    await admin.query('UPDATE ritc.shop SET shopper_id=$3,authority_epoch=authority_epoch+1,revision=revision+1 WHERE household_id=$1 AND shop_id=$2',
      [f.h,f.shopId,f.actors.Lee.id]);
    const base={authorityEpoch:2,shopRevision:accepted.shopRevision+1};
    assert.equal(ok(await f.http('Lee','GET',path)).choice,'undecided');
    code(await f.command('Lee','shop.patch',{quote:f.quote,lines:[{...f.line,originalItem:'Approved for the original shopper'}]},base),'substitution_changed');
    ok(await f.command('Lee','shop.patch',{quote:f.quote,lines:[{...f.line,packs:2}]},base));
  });
  run('a changed target requires a new share and retains packs already picked',async f=>{
    const g=ok(await f.manage(f.grant())),picked=f.op('Alex',g);ok(await f.act('Alex',picked));
    const changed=ok(await f.command('Mia','shop.patch',{quote:f.quote,lines:[{...f.line,packs:3}]}));
    assert.deepEqual(ok(await f.read('Alex')).rows,[]);
    assert.equal((await f.act('Alex',picked)).status,404);
    const next=ok(await f.manage(f.grant({expectedPermissionId:g.permissionId,shopRevision:changed.shopRevision})));
    assert.equal(next.rows[0].picked,1);assert.equal(next.rows[0].packs,3);
    code(await f.act('Alex',f.op('Alex',next,{packs:3})),'stale_base');
    assert.equal(ok(await f.act('Alex',f.op('Alex',next,{packs:2}))).picked,3);
  });
  run('two enrolled adults race the final pack, retry, undo and revoke without checkout authority',async f=>{
    const privateLine=randomUUID();
    await admin.query("INSERT INTO ritc.basket_line(household_id,shop_id,line_id,original_item,packs,fee_eligible) VALUES($1,$2,$3,'Unshared pack',7,true)",[f.h,f.shopId,privateLine]);
    const change=f.grant(),g=ok(await f.manage(change));
    assert.deepEqual(ok(await f.manage(change)),g);
    const guest=ok(await f.read('Alex'));
    assert.deepEqual(guest.members,[]);assert.deepEqual(guest.availableRows,[]);assert.deepEqual(guest.rows.map(r=>r.id),[f.lineId]);
    assert(!JSON.stringify(guest).includes('Unshared pack'));
    assert.equal((await f.read('Lee')).status,404);
    assert.equal((await f.act('Alex',f.op('Alex',g,{rowId:privateLine}))).status,404);
    assert.equal((await f.act('Alex',f.op('Mia',g))).status,404);
    const moves=['Mia','Alex'].map(name=>f.op(name,g));
    const responses=await Promise.all(moves.map((m,i)=>f.act(['Mia','Alex'][i],m)));
    assert.deepEqual(responses.map(r=>r.status).sort(),[200,409]);
    const index=responses.findIndex(r=>r.status===200),winner=['Mia','Alex'][index],loser=['Mia','Alex'][1-index];
    const accepted=ok(responses[index]);assert.equal(accepted.picked,1);
    assert.deepEqual(ok(await f.act(winner,moves[index])),accepted);
    code(await f.act(winner,{...moves[index],packs:2}),'key_reused');
    const snapshot=ok(await f.read(winner)),row=snapshot.rows[0];
    assert.equal(row.lastActorLabel,winner);assert.equal(row.undoOperationId,accepted.operationId);
    const undo=f.op(winner,snapshot,{action:'undo',undoOperationId:accepted.operationId});delete undo.packs;
    ok(await f.act(winner,undo));assert.equal(ok(await f.read()).rows[0].picked,0);
    assert.deepEqual(ok(await f.act(winner,moves[index])),accepted);
    const claim=f.op(loser,ok(await f.read()),{action:'claim'});delete claim.packs;
    ok(await f.act(loser,claim));
    const claimed=ok(await f.read());assert.equal(claimed.rows[0].claimedByLabel,loser);
    code(await f.act(winner,f.op(winner,claimed)),'stale_base');
    const pick=f.op(loser,claimed);ok(await f.act(loser,pick));
    ok(await f.manage(f.grant({expectedPermissionId:g.permissionId,recipientId:null,lineIds:[],expiresAt:null})));
    assert.equal((await f.read('Alex')).status,404);
    assert.equal((await f.act(loser,pick)).status,404);assert.equal((await f.act(winner,moves[index])).status,404);
    const next=ok(await f.manage(f.grant()));assert.notEqual(next.permissionId,g.permissionId);assert.equal(next.rows[0].picked,1);
    assert.equal((await f.act(loser,pick)).status,404);
    assert.equal((await f.command('Alex','shop.freeze',{})).status,404);ok(await f.command('Mia','shop.freeze',{}));
  });
  run('expiry, block, row edit, device and selected helper scope fence queued operations',async f=>{
    const opts=tripConfiguration({});assert.equal(opts.sharedPicking,false);assert.equal(opts.tripSubstitutions,false);
    assert.throws(()=>tripConfiguration({SHARED_PICKING_ENABLED:'true'}));
    assert.equal((await f.manage(f.grant({recipientId:f.actors.Sam.id}))).status,404);
    assert.equal((await f.manage(f.grant(),'Alex')).status,404);
    const g=ok(await f.manage(f.grant()));
    assert.equal((await f.read('Sam')).status,404);
    await admin.query(`INSERT INTO ritc.view_grant(household_id,grant_id,shop_id,created_by,recipient_id,mode,projection,expires_at)
      VALUES($1,$2,$3,$4,$5,'read','{}',now()+interval '1 hour')`,[f.h,f.actors.Jo.id,f.shopId,f.actors.Mia.id,f.actors.Lee.id]);
    assert.equal((await f.http('Lee','GET',f.path,undefined,{'X-View-Grant-ID':f.actors.Jo.id})).status,404);
    assert.equal((await f.act('Alex',f.op('Alex',g,{deviceId:f.actors.Lee.deviceId}))).status,404);
    const picked=f.op('Alex',g);ok(await f.act('Alex',picked));
    const source={kind:'pickingRow',id:g.rows[0].safetyId,revision:1,field:'label'};
    const report=ok(await f.http('Alex','POST','/moderation/actions',{clientKey:randomUUID(),action:'report',reason:'other',source}));
    await admin.query("SELECT ritc.moderation_resolve($1,'remove')",[report.receiptId]);
    assert.deepEqual(ok(await f.read('Alex')).rows,[]);
    assert.equal((await f.act('Alex',picked)).status,404);
    await admin.query("UPDATE ritc.basket_line SET original_item='Changed pack' WHERE household_id=$1 AND shop_id=$2 AND line_id=$3",[f.h,f.shopId,f.lineId]);
    assert.deepEqual(ok(await f.read('Alex')).rows,[]);
    const current=ok(await f.manage(f.grant({expectedPermissionId:g.permissionId})));
    assert.equal(current.rows[0].picked,0);
    const next=f.op('Alex',current);ok(await f.act('Alex',next));
    await admin.query("UPDATE ritc.trip_picking_permission SET expires_at=now()-interval '1 second' WHERE household_id=$1",[f.h]);
    assert.equal((await f.read('Alex')).status,404);assert.equal((await f.act('Alex',next)).status,404);
    const renewed=ok(await f.manage(f.grant()));assert.equal(renewed.rows[0].picked,1);
    ok(await f.http('Alex','POST','/moderation/actions',{clientKey:randomUUID(),action:'block',
      source:{...source,id:renewed.rows[0].safetyId}}));
    assert.equal((await f.read('Alex')).status,404);assert.equal((await f.manage(f.grant())).status,404);
    repo.options.sharedPicking=false;
    assert.equal((await f.read()).status,404);
    assert(!ok(await f.http('Mia','GET','/bootstrap')).capabilities.includes('shared_picking'));
  });
}
