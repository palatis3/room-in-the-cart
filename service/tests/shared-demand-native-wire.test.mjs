import test from 'node:test';
import assert from 'node:assert/strict';
import {PassThrough} from 'node:stream';
import {setImmediate} from 'node:timers/promises';
import {observeNativeWireCommand,observeNativeWireCatalogRequest} from './shared-demand-native-wire.mjs';

// The real API awaits authentication before reading its IncomingMessage. This
// models that boundary without a database, Swift, a listener or artificial load.
async function delayedAPIReader(observe){
 const request=new PassThrough(),bytes=Buffer.from('{"v":1,"body":{"accepted":true}}');let observed;
 observe(request,value=>{observed=value;});
 request.write(bytes.subarray(0,9));request.end(bytes.subarray(9));
 await setImmediate();
 const consumed=[];for await(const chunk of request)consumed.push(chunk);
 return {expected:bytes,observed,consumed:Buffer.concat(consumed)};
}
test('former flowing wire observation consumes the command before authorized API reader',async()=>{
 const result=await delayedAPIReader((request,received)=>{const chunks=[];request.on('data',chunk=>chunks.push(chunk));request.on('end',()=>received(Buffer.concat(chunks)));});
 assert.deepEqual(result.observed,result.expected);
 assert.equal(result.consumed.length,0);
 assert.throws(()=>JSON.parse(result.consumed.toString()),SyntaxError);
});
test('paused wire observation preserves exact command bytes for delayed original API reader',async()=>{
 const result=await delayedAPIReader(observeNativeWireCommand);
 assert.deepEqual(result.consumed,result.expected);assert.deepEqual(result.observed,result.expected);
 assert.deepEqual(JSON.parse(result.consumed.toString()),{v:1,body:{accepted:true}});
});

test('catalog synchronization keeps exact body for original authorized API and awaits mutation',async()=>{
 const request=new PassThrough(),bytes=Buffer.from('{"base":{"graphRevision":1},"action":{"kind":"shop.patch"}}');let observed,release,completed=false;
 const barrier=new Promise(resolve=>{release=resolve;});
 const pending=observeNativeWireCatalogRequest(request,value=>{observed=value;},async()=>{await barrier;completed=true;});
 request.write(bytes.subarray(0,7));request.end(bytes.subarray(7));await setImmediate();assert.equal(completed,false);assert.equal(observed,undefined);
 release();await pending;assert.equal(completed,true);
 const chunks=[];for await(const chunk of request)chunks.push(chunk);
 assert.deepEqual(Buffer.concat(chunks),bytes);assert.deepEqual(observed,bytes);
});
test('failed catalog synchronization rejects before dispatch without consuming body',async()=>{
 const request=new PassThrough();const pending=observeNativeWireCatalogRequest(request,()=>{},async()=>{throw Error('fixture denied');});
 request.end('exact body');await assert.rejects(pending,/fixture denied/);
 const chunks=[];for await(const chunk of request)chunks.push(chunk);assert.equal(Buffer.concat(chunks).toString(),'exact body');
});
