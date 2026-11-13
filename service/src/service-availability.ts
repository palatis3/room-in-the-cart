import type {IncomingMessage,ServerResponse} from 'node:http';

export type ServiceAvailability = {mode:'serving'} | {mode:'maintenance';configuration:'enabled'|'invalid'};
/** Only an absent value or the exact literal false permits normal startup. */
export function serviceAvailability(environment:NodeJS.ProcessEnv):ServiceAvailability {
 const value=environment.SERVICE_MAINTENANCE;
 if(value===undefined||value==='false')return{mode:'serving'};
 return{mode:'maintenance',configuration:value==='true'?'enabled':'invalid'};
}

/** No identity, provider, body or database work; applies to every routed request. */
export function maintenanceResponse(_request:IncomingMessage,response:ServerResponse):void {
 response.writeHead(503,{'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store',
  'Retry-After':'60','Connection':'close','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer'});
 response.end(JSON.stringify({error:{code:'service_unavailable',recovery:'Keep saved changes and try again later.'}}));
}
