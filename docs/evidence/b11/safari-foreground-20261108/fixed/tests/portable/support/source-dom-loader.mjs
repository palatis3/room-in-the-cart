import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import ts from 'typescript';
import {JSDOM} from 'jsdom';
import {IDBFactory} from 'fake-indexeddb';
export {JSDOM};
const sourceDirectory=fileURLToPath(new URL('../../src/',import.meta.url));
// Execute the actual source entry point with per-document API/storage dependencies.
// CSS is intentionally ignored; this is DOM/lifecycle coverage, not layout/browser proof.
export function loadApplication(dom,api) {
 const cache=new Map();let instance;
 function load(name) {
  if(cache.has(name))return cache.get(name).exports;
  const module={exports:{}};cache.set(name,module);
  const code=fs.readFileSync(path.join(sourceDirectory,name+'.ts'),'utf8');
  const compiled=ts.transpileModule(code,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  function localRequire(ref) {
   if(ref.endsWith('.css'))return {};
   if(!ref.startsWith('./'))throw Error('Unexpected runtime dependency '+ref);
   const dependency=ref.slice(2).replace(/\.js$/,'');const exports=load(dependency);
   if(name==='main'&&dependency==='app')return {WebApp:class extends exports.WebApp{constructor(root,_a,_o,token){super(root,api,new (load('outbox').Outbox)(new IDBFactory()),token);instance=this;}}};
   return exports;
  }
  new Function('require','module','exports','window','document',compiled)(localRequire,module,module.exports,dom?.window,dom?.window?.document);
  return module.exports;
 }
 const apiModule=load('api');load('main');
 return {app:instance,ApiError:apiModule.ApiError};
}
