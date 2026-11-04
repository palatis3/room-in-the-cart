import {fileURLToPath} from 'node:url';
import {createOperationsRuntime} from './operations-runtime.js';

export async function operationsCLI(args:string[]=process.argv.slice(2),environment:NodeJS.ProcessEnv=process.env){
 if(args.length!==1||!['run','status'].includes(args[0]!)){
  console.error('Usage: npm run operations -- run|status');return 2;
 }
 let runtime:ReturnType<typeof createOperationsRuntime>|undefined;
 try{
  runtime=createOperationsRuntime(environment);
  console.info(JSON.stringify(await runtime.run(args[0] as 'run'|'status')));return 0;
 }catch{console.error(JSON.stringify({event:'operations_failed',error:'operations_unavailable'}));return 1;}
 finally{await runtime?.close();}
}
if(process.argv[1]===fileURLToPath(import.meta.url))process.exitCode=await operationsCLI();
