import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';

// Distinct from the adults whose erasures are replayed in the signed restore test.
export async function restoredMealPermissions(admin, family, recipient) {
  const {h, shopId, owner} = family;
  const target = randomUUID(), invite = randomUUID(), question = randomUUID(), step = randomUUID();
  const common = [h, shopId, owner.id];
  await admin.query('INSERT INTO ritc.billing_account(household_id,purchaser_id,app_account_token) VALUES($1,$2,$3)', [h,owner.id,randomUUID()]);
  await admin.query("INSERT INTO ritc.billing_state(household_id,purchaser_id,subscription,verified_at) VALUES($1,$2,'{}',now())", [h,owner.id]);
  await admin.query("INSERT INTO ritc.billing_seat VALUES($1,1,$2,'Shopper'),($1,2,$3,'Planner')", [h,owner.id,recipient.id]);
  await admin.query(`INSERT INTO ritc.adult_check(household_id,shop_id,shopper_id,recipient_id,source_id,check_id,
    kind,step_text,step_sender,shop_revision,authority_epoch,pair_revision,created_at,expires_at,answer,answered_at)
    VALUES($1,$2,$3,$4,$5,$6,'attendance',NULL,NULL,1,1,1,now(),now()+interval '1 day','home',now()),
          ($1,$2,$3,$4,$5,$7,'cookStep','Rinse rice',$3,1,1,1,now(),now()+interval '1 day','accepted',now())`,
    [...common,recipient.id,target,question,step]);
  await admin.query(`INSERT INTO ritc.invite(household_id,invite_id,token_hash,kind,created_by,expires_at,
    dinner_shop_id,dinner_occurrence_id,dinner_authority_epoch)
    VALUES($1,$4,repeat('d',64),'adult_contributor',$3,now()+interval '1 day',$2,$5,1)`, [...common,invite,target]);
  const next=randomUUID(), receipt=randomUUID();
  for (const complete of [false,true]) {
    const day=complete?'2026-11-30':'2026-11-23';
    await admin.query(`INSERT INTO ritc.shared_repeat_week(household_id,shop_id,actor_id,week_start,plan_id,
      authority_epoch,grant_revision,request_digest,steps,receipts)
      VALUES($1,$2,$3,$4,$5,1,1,repeat('a',64),$6,$7)`, [...common,day,randomUUID(),
      JSON.stringify([{targetId:next},...(complete?[]:[{targetId:target}])]),{[next]:receipt}]);
    await admin.query(`INSERT INTO ritc.saved_week_change(household_id,shop_id,actor_id,week_start,plan_id,
      authority_epoch,grant_revision,initial_revision,review_digest,steps,receipts)
      VALUES($1,$2,$3,$4,$5,1,1,1,repeat('a',64),$6,$7)`, [...common,day,randomUUID(),
      JSON.stringify([{id:next},...(complete?[]:[{id:target}])]),JSON.stringify([receipt])]);
  }

  return async (db, retired) => {
    const checks=(await db.query(`SELECT check_id,withdrawn,answer,step_text FROM ritc.adult_check
      WHERE household_id=$1 ORDER BY kind`,[h])).rows;
    assert.deepEqual(checks,[
      {check_id:question,withdrawn:retired,answer:retired?null:'home',step_text:null},
      {check_id:step,withdrawn:retired,answer:retired?null:'accepted',step_text:retired?null:'Rinse rice'}
    ]);
    const invitation=(await db.query('SELECT revoked_at IS NOT NULL AS retired FROM ritc.invite WHERE invite_id=$1',[invite])).rows[0];
    assert.equal(invitation.retired,retired);
    for (const table of ['shared_repeat_week','saved_week_change']) {
      const plans=(await db.query(`SELECT stopped,receipts FROM ritc.${table} WHERE household_id=$1 ORDER BY week_start`,[h])).rows;
      assert.deepEqual(plans.map(p=>p.stopped),[retired,false]);
      for(const plan of plans) assert.deepEqual(Object.values(plan.receipts),[receipt]);
    }
    assert.equal((await db.query('SELECT count(*)::int AS n FROM ritc.billing_seat WHERE household_id=$1',[h])).rows[0].n,2);
  };
}
