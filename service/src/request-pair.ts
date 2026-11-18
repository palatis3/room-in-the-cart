import type { RequestPairEvidence, RequestPairReference } from '../../shared/contracts/service-v1.js';
import type { Decision } from './contracts.js';
import { digest } from './database.js';
import { refresh, unavailable } from './errors.js';
import type { Context, HouseholdRepository, RequestRow, Shop } from './repository.js';
import { normalizedRequestItem, requireLiveAuthor } from './request-same-item.js';

type PairDecision = Extract<Decision,{choice:'reviewRequestPair'|'undoRequestPair'}>;
interface Pair {
  request_id:string; request_revision:number; other_id:string; other_revision:number;
  relationship:RequestPairEvidence['relationship']; operation_id:string; undo_operation_id:string|null; invalidated:boolean;
}

function requireOpen(repo:HouseholdRepository, request:RequestRow) {
  requireLiveAuthor(repo,request);
  if (request.carried_forward || request.route !== 'current' || !['pending','clarified'].includes(request.status)) throw refresh();
}

async function operationPair(ctx:Context,shop:Shop,operationId:string) {
  return (await ctx.db.query<Pair>(`SELECT * FROM ritc.request_pair_review WHERE household_id=$1 AND shop_id=$2
    AND (operation_id=$3 OR undo_operation_id=$3)`,[ctx.householdId,shop.shop_id,operationId])).rows[0];
}

export async function reviewPair(repo:HouseholdRepository,ctx:Context,shop:Shop,request:RequestRow,decision:PairDecision) {
  repo.requireShopper(ctx,shop);
  repo.requireDraft(shop);
  requireOpen(repo,request);
  let otherId:string, otherRevision:number, relationship:RequestPairEvidence['relationship'];
  let generation=0;
  if (decision.choice==='undoRequestPair') {
    const pair=await operationPair(ctx,shop,decision.operationId);
    if (!pair || pair.operation_id!==decision.operationId || ![pair.request_id,pair.other_id].includes(request.request_id)) throw unavailable();
    if (pair.invalidated || pair.undo_operation_id) throw refresh();
    const first=request.request_id===pair.request_id;
    if (request.revision!==(first?pair.request_revision:pair.other_revision)) throw refresh();
    otherId=first?pair.other_id:pair.request_id;
    otherRevision=first?pair.other_revision:pair.request_revision;
    relationship=pair.relationship;
  } else {
    otherId=decision.otherRequestId; otherRevision=decision.otherRequestRevision; relationship=decision.relationship;
    if (request.request_id===otherId) throw unavailable();
  }
  const other=await repo.request(ctx,otherId,shop.shop_id);
  requireOpen(repo,other);
  if (other.revision!==otherRevision || normalizedRequestItem(other.original_item)!==normalizedRequestItem(request.original_item)) throw refresh();
  if (decision.choice==='reviewRequestPair') {
    // Count completed reviews so a preview opened before another apply and undo cannot silently reapply it.
    const {rows}=await ctx.db.query<{count:number;active:boolean}>(`SELECT count(*)::int AS count,
      coalesce(bool_or(undo_operation_id IS NULL AND NOT invalidated),false) AS active FROM ritc.request_pair_review
      WHERE household_id=$1 AND operation_id IS NOT NULL
        AND (least(request_id,other_id),greatest(request_id,other_id))=(least($2::uuid,$3::uuid),greatest($2::uuid,$3::uuid))`,
      [ctx.householdId,request.request_id,otherId]);
    if (rows[0]!.active) throw refresh();
    generation=rows[0]!.count;
  }
  const evidence:RequestPairEvidence={otherRequestId:otherId,otherRequestRevision:otherRevision,relationship,
    item:other.original_item,quantity:other.own_quantity,authorAlias:other.author_alias};
  return {evidence,fingerprint:digest({generation,evidence,status:other.status,clarification:other.clarification,
    authors:[request.author_id,request.author_alias,other.author_id]})};
}

export async function rememberPair(ctx:Context,shop:Shop,request:RequestRow,previewId:string,evidence:RequestPairEvidence) {
  await ctx.db.query(`INSERT INTO ritc.request_pair_review(household_id,shop_id,preview_id,request_id,request_revision,
    other_id,other_revision,relationship) VALUES($1,$2,$3,$4,$5,$6,$7,$8)`,[ctx.householdId,shop.shop_id,previewId,
    request.request_id,request.revision,evidence.otherRequestId,evidence.otherRequestRevision,evidence.relationship]);
}

export async function applyPair(ctx:Context,shop:Shop,previewId:string,decision:PairDecision,operationId:string) {
  const result=decision.choice==='reviewRequestPair'
    ? await ctx.db.query(`UPDATE ritc.request_pair_review SET operation_id=$4 WHERE household_id=$1 AND shop_id=$2
        AND preview_id=$3 AND operation_id IS NULL AND NOT invalidated`,[ctx.householdId,shop.shop_id,previewId,operationId])
    : await ctx.db.query(`UPDATE ritc.request_pair_review SET undo_operation_id=$4 WHERE household_id=$1 AND shop_id=$2
        AND operation_id=$3 AND undo_operation_id IS NULL AND NOT invalidated`,[ctx.householdId,shop.shop_id,decision.operationId,operationId]);
  if (result.rowCount!==1) throw refresh();
}

export async function checkPairReplay(repo:HouseholdRepository,ctx:Context,shop:Shop,operationId:string,epoch:number) {
  const pair=await operationPair(ctx,shop,operationId);
  if (!pair) return;
  if (epoch!==shop.authority_epoch || shop.phase!=='draft' || pair.invalidated ||
      pair.operation_id===operationId && pair.undo_operation_id) throw refresh();
  if (pair.undo_operation_id===operationId) {
    const newer=await ctx.db.query(`SELECT 1 FROM ritc.request_pair_review WHERE household_id=$1 AND operation_id IS NOT NULL
      AND undo_operation_id IS NULL AND NOT invalidated
      AND (least(request_id,other_id),greatest(request_id,other_id))=(least($2::uuid,$3::uuid),greatest($2::uuid,$3::uuid))`,
      [ctx.householdId,pair.request_id,pair.other_id]);
    if (newer.rowCount) throw refresh();
  }
  for (const [id,revision] of [[pair.request_id,pair.request_revision],[pair.other_id,pair.other_revision]] as const) {
    const request=await repo.request(ctx,id,shop.shop_id);
    requireOpen(repo,request);
    if (request.revision!==revision) throw refresh();
  }
}

export async function inboxPairs(ctx:Context,shop:Shop,ids:string[],notice:string|null) {
  const pairs=new Map<string,RequestPairReference[]>();
  if (shop.phase!=='draft'||!ids.length) return pairs;
  const {rows}=await ctx.db.query<Pair>(`SELECT p.* FROM ritc.request_pair_review p
    JOIN ritc.request_origin a ON (a.household_id,a.shop_id,a.request_id,a.revision)=(p.household_id,p.shop_id,p.request_id,p.request_revision)
    JOIN ritc.request_origin b ON (b.household_id,b.shop_id,b.request_id,b.revision)=(p.household_id,p.shop_id,p.other_id,p.other_revision)
    WHERE p.household_id=$1 AND p.shop_id=$2 AND (p.request_id=ANY($3::uuid[]) OR p.other_id=ANY($3::uuid[]))
    AND p.operation_id IS NOT NULL AND p.undo_operation_id IS NULL AND NOT p.invalidated
    AND a.author_active AND (a.author_kind='adult' OR a.live_notice=$4) AND b.author_active AND (b.author_kind='adult' OR b.live_notice=$4)
    AND NOT a.carried_forward AND NOT b.carried_forward AND a.route='current' AND b.route='current'
    AND a.status IN ('pending','clarified') AND b.status IN ('pending','clarified') ORDER BY p.operation_id`,
    [ctx.householdId,shop.shop_id,ids,notice]);
  for (const p of rows) {
    for (const [id,otherRequestId,otherRequestRevision] of [[p.request_id,p.other_id,p.other_revision],[p.other_id,p.request_id,p.request_revision]] as const) {
      const list=pairs.get(id)??[];
      list.push({otherRequestId,otherRequestRevision,relationship:p.relationship,operationId:p.operation_id});
      pairs.set(id,list);
    }
  }
  return pairs;
}
