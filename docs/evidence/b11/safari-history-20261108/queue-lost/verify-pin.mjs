import assert from 'node:assert/strict';
import {readFile,readdir,lstat} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {join,dirname} from 'node:path';
import {sha} from './fixture.mjs';
export const here=dirname(fileURLToPath(import.meta.url));
async function names(root,prefix=''){const result=[];for(const e of await readdir(join(root,prefix),{withFileTypes:true})){assert(!e.isSymbolicLink());const name=join(prefix,e.name);if(e.isDirectory())result.push(...await names(root,name));else{assert(e.isFile());result.push(name);}}return result.sort();}
export async function verifyPin(){const m=JSON.parse(await readFile(join(here,'manifest.json'),'utf8'));const {identity,...payload}=m;assert.equal(sha(JSON.stringify(payload)),identity);assert.deepEqual(await names(join(here,'bundle')),Object.keys(m.bundle).sort());for(const [name,want]of Object.entries(m.bundle))assert.equal(sha(await readFile(join(here,'bundle',name))),want);if(m.verifiedBuild)assert.equal(sha(await readFile(m.verifiedBuild.receipt)),m.verifiedBuild.sha256);for(const [name,want]of Object.entries(m.helpers))assert.equal(sha(await readFile(join(here,name))),want);return m;}
