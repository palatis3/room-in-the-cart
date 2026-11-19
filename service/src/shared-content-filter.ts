import type {Context} from './repository.js';
import type {z} from 'zod';
import type {viewProjectionSchema} from './contracts.js';
import {ServiceError} from './errors.js';

// Match directed threats, harassment and explicit sexual solicitation. Check
// phrases with word boundaries so food names are never substring matches.
const harmfulPhrases = [
  /\b(?:i (?:will|ll|am going to)|i m (?:going to|gonna)|im gonna) (?:kill|hurt|rape) you\b/,
  /\b(?:go kill yourself|kill yourself|go die|send (?:me )?(?:nudes|naked pictures)|show me your (?:dick|tits))\b/,
  /\b(?:fuck (?:you|off)|you(?: re| are)? (?:a |an )?(?:piece of shit|worthless (?:idiot|bitch)|stupid (?:bitch|asshole)|fucking (?:idiot|moron)))\b/,
  /\b(?:you(?: re| are)? (?:a |an )?(?:worthless|stupid) (?:idiot|moron)|you(?: re| are) (?:a |an )?(?:bitch|asshole)|nigg(?:er|ers)|sieg heil)\b/,
  /\b(?:te (?:voy a|vamos a) (?:matar|violar|pegar|hacer dano)|(?:voy|vamos) a (?:matarte|violarte)|te matare|te violare|matate|suicidate)\b/,
  /\b(?:vete a la mierda|hij[oa] de puta|eres (?:un |una )?(?:put[oa]|imbecil|idiota)|(?:manda|mandame|enviame) (?:fotos (?:desnud[oa]s?|intimas)|nudes))\b/,
];

function normalized(value:string):string {
  return value.normalize('NFKD').toLowerCase().replace(/\p{M}/gu,'')
    .replace(/\p{Cf}/gu,'').replace(/[^\p{L}\p{N}]+/gu,' ').trim();
}

export function reviewSharedWording(...fields:(string|null)[]) {
  const wording=normalized(fields.join(' '));
  if(harmfulPhrases.some(pattern=>pattern.test(wording))) {
    throw new ServiceError(422,'content_review_required','Edit the shared wording and try again.');
  }
}

export async function checkPublishingMember(ctx:Context) {
  const result=await ctx.db.query('SELECT ritc.content_account_suspended($1,$2) AS suspended',[ctx.householdId,ctx.member.member_id]);
  if(result.rows[0]?.suspended!==false) throw new ServiceError(403,'shared_posting_unavailable','Shared posting is unavailable for this account.');
}

type Projection=z.infer<typeof viewProjectionSchema>;
export async function reviewInstruction(ctx:Context,input:Projection) {
  await checkPublishingMember(ctx);
  const fields=input.items.flatMap(row=>[row.label,row.amount,row.unit,row.action]);
  reviewSharedWording(input.shopLabel,...fields);
}
