import {fileURLToPath} from 'node:url';
import {createOperationsRuntime} from './operations-runtime.js';

export async function operationsCLI(args:string[]=process.argv.slice(2),environment:NodeJS.ProcessEnv=process.env){
 const [mode,option]=args;
 const check=mode==='status'&&args.length===2&&option==='--check';
 if((mode!=='run'&&mode!=='status')||(!check&&args.length!==1)){
  console.error('Usage: npm run operations -- run | status [--check]');return 2;
 }
 let runtime:ReturnType<typeof createOperationsRuntime>|undefined;
 try{
  runtime=createOperationsRuntime(environment);
  const result=await runtime.run(mode);
  console.info(JSON.stringify(result));
  return check&&result.attentionRequired?3:0;
 }catch{console.error(JSON.stringify({event:'operations_failed',error:'operations_unavailable'}));return 1;}
 finally{await runtime?.close();}
}
if(process.argv[1]===fileURLToPath(import.meta.url))process.exitCode=await operationsCLI();
