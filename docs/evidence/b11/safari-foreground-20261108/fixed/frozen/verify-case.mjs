// Read-only post-execution CLI; never launches the case being checked.
import {readFile} from 'node:fs/promises';import {verifyPin} from './verify-pin.mjs';import {verifyForeground} from './verify-foreground.mjs';
const [name,path]=process.argv.slice(2);const m=await verifyPin();const receipt=JSON.parse(await readFile(path,'utf8'));console.log(JSON.stringify(verifyForeground(receipt,m.identity,name)));
