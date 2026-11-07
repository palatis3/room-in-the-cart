import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {mealPlanning,preserveProtectedMeal} from '../dist/shared-meal-planning.js';
import {sharedIdeaDraftSchema,evaluateSharedIdea,sharedIdeaWriteSchema} from '../dist/shared-meal-ideas.js';
const ingredient=()=>({id:randomUUID(),name:'Rice',required:600,unit:'gram',stock:500,reservations:[{name:'Tuesday lunch',amount:250}],pack:400,usableNumerator:3,usableDenominator:4,evidence:'Household pantry checked and package label entered'});
const draft=()=>({title:'Rice bowl',source:'manual',servings:2,minutes:20,assumedExtras:[],exclusions:[],ingredients:[ingredient()]});
test('named reservations are deducted before exact usable whole packs, with price unresolved',()=>{const result=evaluateSharedIdea(sharedIdeaDraftSchema.parse(draft()));assert.equal(result.canApprove,true);assert.deepEqual({...result.ingredients[0],ingredientId:null},{ingredientId:null,excluded:false,reserved:250,remaining:250,shortage:350,wholePacks:2,unresolvedPrice:true,arithmeticUnavailable:false});});
test('unknown stock, pack, yield or required amount blocks coverage and approval',()=>{for(const key of ['stock','pack','usableNumerator','usableDenominator','required']){const value=draft();value.ingredients[0][key]=null;const result=evaluateSharedIdea(sharedIdeaDraftSchema.parse(value));assert.equal(result.canApprove,false,key);assert.equal(result.ingredients[0].wholePacks,null,key);}});
test('excluded ingredient blocks approval until replaced or removed; accents and case cannot bypass',()=>{const value=draft();value.exclusions=['RÍCE'];assert.equal(evaluateSharedIdea(value).canApprove,false);value.ingredients[0].name='Beans';assert.equal(evaluateSharedIdea(value).canApprove,true);});
test('zero stock is explicit evidence; reserved amounts never create negative stock credit',()=>{const value=draft();value.ingredients[0].stock=0;const result=evaluateSharedIdea(value).ingredients[0];assert.equal(result.remaining,0);assert.equal(result.wholePacks,2);});
test('invalid yield, duplicate ingredient identity and invented private price fields fail closed',()=>{for(const mutate of [v=>v.ingredients[0].usableNumerator=5,v=>v.ingredients.push(v.ingredients[0]),v=>v.ingredients[0].price=123]){const value=draft();mutate(value);assert.equal(sharedIdeaDraftSchema.safeParse(value).success,false);}});
test('write binds exact shop authority and separates save from approval',()=>{const request={clientKey:randomUUID(),ideaId:randomUUID(),baseRevision:null,shopRevision:1,authorityEpoch:1,grantRevision:1,action:'save',draft:draft(),reviewedHouseholdEvidence:false};assert.equal(sharedIdeaWriteSchema.safeParse(request).success,true);assert.equal(sharedIdeaWriteSchema.safeParse({...request,authorityEpoch:0}).success,false);assert.equal(sharedIdeaWriteSchema.safeParse({...request,action:'apply'}).success,false);});

test('fractional cups and named reserves use exact arithmetic through usable pack yield',()=>{
 const value=draft(),i=value.ingredients[0];Object.assign(i,{unit:'cup',required:{numerator:1,denominator:2},stock:{numerator:1,denominator:4},reservations:[{name:'Lunch',amount:{numerator:1,denominator:8}}],pack:1,usableNumerator:1,usableDenominator:2});
 const result=evaluateSharedIdea(sharedIdeaDraftSchema.parse(value));assert.equal(result.canApprove,true);
 assert.deepEqual(result.ingredients[0].reserved,{numerator:1,denominator:8});assert.deepEqual(result.ingredients[0].remaining,{numerator:1,denominator:8});assert.deepEqual(result.ingredients[0].shortage,{numerator:3,denominator:8});assert.equal(result.ingredients[0].wholePacks,1);
});
test('fractional packs, ounce and fluid ounce stay distinct without unit conversion or rounding',()=>{
 const value=draft();value.ingredients=[...['ounce','fluidOunce','kilogram','pound','liter','cup','gram','milliliter','count'].map(unit=>({...ingredient(),id:randomUUID(),unit,required:{numerator:1,denominator:2},stock:0,reservations:[],pack:{numerator:1,denominator:3},usableNumerator:1,usableDenominator:2}))];
 const parsed=sharedIdeaDraftSchema.parse(value),result=evaluateSharedIdea(parsed);assert.equal(result.canApprove,true);assert.ok(result.ingredients.every(i=>i.wholePacks===3));assert.equal(parsed.ingredients[0].unit,'ounce');assert.equal(parsed.ingredients[1].unit,'fluidOunce');
});
test('invalid fractions fail closed and unrepresentable exact previews stay unresolved',()=>{
 for(const amount of [{numerator:1,denominator:0},{numerator:-1,denominator:2},0.5]){const value=draft();value.ingredients[0].required=amount;assert.equal(sharedIdeaDraftSchema.safeParse(value).success,false);}
 const value=draft();value.ingredients[0].reservations=[999983,999979,999961,999959].map(denominator=>({name:'Reserved',amount:{numerator:1,denominator}}));const result=evaluateSharedIdea(sharedIdeaDraftSchema.parse(value));assert.equal(result.canApprove,false);assert.equal(result.ingredients[0].arithmeticUnavailable,true);assert.equal(result.ingredients[0].remaining,null);assert.equal(result.ingredients[0].wholePacks,null);
});

test('reviewed exclusion phrases match whole words in entered ingredient names in either language',()=>{
 const value=draft(),ingredient=value.ingredients[0];
 for(const [restriction,name,conflict] of [
   ['No nuts','Mixed NUTS',true],['sin sésamo','Semillas de SESAMO',true],
   ['without rice','Brown rice flour',true],['No nuts','Donuts',false],
   ['rice','Licorice',false],['Sin nueces','Beans',false],
 ]){
   value.exclusions=[restriction];ingredient.name=name;
   const preview=evaluateSharedIdea(value);
   assert.equal(preview.ingredients[0].excluded,conflict);assert.equal(preview.canApprove,!conflict);
 }
});

test('optional reviewed meal planning details retain their bounds and leave legacy plans unchanged',()=>{
 const base={groups:[],ingredients:[]};
 assert.deepEqual(mealPlanning.parse(base),base);
 for(const minutes of [0,1_000_000]){
   const plan={...base,exclusions:['No nuts'],leadTimeMinutes:minutes,completedSteps:Array(100).fill('x'.repeat(240))};
   assert.deepEqual(mealPlanning.parse(plan),plan);
 }
 for(const change of [{leadTimeMinutes:-1},{leadTimeMinutes:1.1},{leadTimeMinutes:1_000_001},
   {completedSteps:['  ']},{completedSteps:['x'.repeat(241)]},{completedSteps:Array(101).fill('done')},
   {exclusions:['']},{exclusions:Array(21).fill('nuts')}]){
   assert.equal(mealPlanning.safeParse({...base,...change}).success,false);
 }
});

test('meal-wide restrictions cover protected whole meals and individually protected portions',()=>{
 for(const whole of [true,false]){
   const original={title:'Supper',day:'2026-11-09',kind:'dinner',portions:2,protected:whole,planning:{
     groups:whole?[]:[{id:randomUUID(),name:'Lunch',servings:{numerator:1,denominator:1},protected:true}],
     ingredients:[],exclusions:['No nuts','sin sésamo']}};
   for(const exclusions of [undefined,[],['No nuts']]){
     assert.throws(()=>preserveProtectedMeal(original,{...original,planning:{...original.planning,exclusions}}),{code:'protected_meal'});
   }
   assert.doesNotThrow(()=>preserveProtectedMeal(original,{...original,planning:{...original.planning,exclusions:[...original.planning.exclusions,'soy']}}));
 }
});
