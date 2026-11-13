// Pure offline evidence check; no browser/listener/native or filesystem mutation.
import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {dirname,join} from 'node:path';
import {sha} from './frozen/fixture.mjs';
import {verifyForeground} from './frozen/verify-foreground.mjs';
const here=dirname(fileURLToPath(import.meta.url));
async function names(prefix=''){const output=[];for(const entry of await readdir(join(here,prefix),{withFileTypes:true})){assert(!entry.isSymbolicLink());const name=join(prefix,entry.name);if(entry.isDirectory())output.push(...await names(name));else{assert(entry.isFile());output.push(name);}}return output.sort();}
const inventory=JSON.parse(await readFile(join(here,'file-hashes.json'),'utf8'));
assert.deepEqual((await names()).filter(x=>x!=='file-hashes.json'),Object.keys(inventory.files).sort());
for(const [name,want]of Object.entries(inventory.files))assert.equal(sha(await readFile(join(here,name))),want,name);
const manifest=JSON.parse(await readFile(join(here,'harness-manifest.json'),'utf8')),{identity,...payload}=manifest;
assert.equal(sha(JSON.stringify(payload)),identity);
for(const name of ['fixture.mjs','probe.js','observation.mjs','server.mjs','verify-foreground.mjs'])assert.equal(sha(await readFile(join(here,'frozen',name))),manifest.helpers[name],name);
const receiptBytes=await readFile(join(here,'receipt.json')),receipt=JSON.parse(receiptBytes),verification=JSON.parse(await readFile(join(here,'verification.json'),'utf8'));
assert.equal(sha(receiptBytes),verification.receiptSHA256);assert.equal(identity,verification.manifestIdentity);
const result=verifyForeground(receipt,identity,'editor-foreground-revoked');assert.deepEqual(result,verification.result);console.log(JSON.stringify({package:'safari-editor-foreground-20261108',...result}));
