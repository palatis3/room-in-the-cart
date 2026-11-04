import {ApiError, type API, type Session} from './api.js';

export const browserSignOutKey = 'ritc.sign-out.pending';

export function browserSignOutPending(window:Window|null):boolean {
  try { return window?.localStorage.getItem(browserSignOutKey)==='1'; }
  catch { return false; }
}

export function setBrowserSignOutPending(window:Window|null,pending:boolean):void {
  try {
    if(pending)window?.localStorage.setItem(browserSignOutKey,'1');
    else window?.localStorage.removeItem(browserSignOutKey);
  } catch { /* The active page still keeps its in-memory sign-out state. */ }
}

/** A cold reload has only the pending bit. Use current authorization for the retry. */
export async function resumeBrowserSignOut(
  readScope:()=>Promise<Session|null>, api:Pick<API,'logout'|'authState'|'logoutIdentity'>,
):Promise<boolean|null> {
  let scope:Session|null;
  try { scope=await readScope(); }
  catch(error){
    if(!(error instanceof ApiError)||(error.status!==401&&error.status!==403))throw error;
    scope=null;
  }
  if(scope)return (await api.logout(scope))?.providerRevoked??null;
  const identity=await api.authState();
  if(identity.authenticated&&identity.csrf)return (await api.logoutIdentity(identity.csrf)).providerRevoked;
  return null;
}
