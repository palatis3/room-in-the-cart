import { validateOwnCommand, isContributorSession, type Command, type Session } from './api.js';
export interface Pending { id: string; scope: string; command: Command; createdAt: string; needsReview?: true }
export function scopeFor(session: Session): string { return `${session.household.id}/${session.memberId}${session.requestQueueGrant ? "/"+session.requestQueueGrant : ""}`; }
export class Outbox {
  constructor(private readonly factory?: IDBFactory) {}
  private async open(): Promise<IDBDatabase> {
    const factory = this.factory ?? globalThis.indexedDB;
    if (!factory) throw new Error('storage_unavailable');
    return new Promise((resolve, reject) => {
      const request = factory.open('room-in-the-cart-own-outbox-v1', 1);
      request.onupgradeneeded = () => request.result.createObjectStore('pending', {keyPath:'id'});
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
      request.onblocked = () => reject(new Error('storage_blocked'));
    });
  }
  async put(pending: Pending, session: Session, consent: boolean): Promise<void> {
    if (!isContributorSession(session) || !session.enrolled || !session.queueConsent || (session.requestQueueUntil && Date.parse(session.requestQueueUntil)<=Date.now()) || !consent || pending.scope !== scopeFor(session) || pending.command.replayWindow !== session.replayWindow.id) throw new Error('storage_not_allowed');
    validatePending(pending);
    const db = await this.open();
    try { await new Promise<void>((resolve,reject) => {
      const tx = db.transaction('pending','readwrite'); tx.objectStore('pending').put(pending);
      tx.oncomplete = () => resolve(); tx.onerror = () => reject(tx.error); tx.onabort = () => reject(tx.error);
    }); } finally { db.close(); }
  }
  async list(scope: string): Promise<Pending[]> {
    const db = await this.open();
    try { return await new Promise((resolve,reject) => {
      const tx = db.transaction('pending','readonly'); const request = tx.objectStore('pending').getAll();
      tx.oncomplete = () => {
        try { const rows = (request.result as Pending[]).filter(p => p.scope === scope); rows.forEach(validatePending); resolve(rows); } catch (error) { reject(error); }
      };
      tx.onerror = () => reject(tx.error); tx.onabort = () => reject(tx.error);
    }); } finally { db.close(); }
  }
  retainScope(scope: string): Promise<void> { return this.removeScopes(stored => stored !== scope); }
  clearScope(scope: string): Promise<void> { return this.removeScopes(stored => stored === scope); }
  private async removeScopes(shouldRemove:(scope:string)=>boolean): Promise<void> {
    const db = await this.open();
    try { await new Promise<void>((resolve,reject) => {
      const tx = db.transaction('pending','readwrite'), store = tx.objectStore('pending'), cursor = store.openCursor();
      cursor.onsuccess = () => { const row = cursor.result; if (row) { if (shouldRemove(row.value.scope)) row.delete(); row.continue(); } };
      tx.oncomplete = () => resolve(); tx.onerror = () => reject(tx.error); tx.onabort = () => reject(tx.error);
    }); } finally { db.close(); }
  }
  // Update only an existing edit in its original scope. A retry in another tab
  // must not recreate a removed row or move the same correction into two drafts.
  async reviewEdit(id:string, scope:string, action:'mark'|'take'):Promise<Pending|null> {
    const db=await this.open();
    try { return await new Promise((resolve,reject)=>{
      const tx=db.transaction('pending','readwrite'), store=tx.objectStore('pending');
      const read=store.get(id);let matched:Pending|null=null;
      read.onsuccess=()=>{
        const row=read.result as Pending|undefined;
        if(!row || row.scope!==scope || row.command.kind!=='request.edit')return;
        try {validatePending(row);} catch {tx.abort();return;}
        if(action==='mark') {
          matched={...row,needsReview:true};store.put(matched);
        } else if(row.needsReview) {
          matched=row;store.delete(id);
        }
      };
      tx.oncomplete=()=>resolve(matched);tx.onabort=()=>reject(tx.error);tx.onerror=()=>reject(tx.error);
    }); } finally {db.close();}
  }
  async remove(id: string): Promise<void> { await this.mutate(store => store.delete(id)); }
  async clear(): Promise<void> { await this.mutate(store => store.clear()); }
  private async mutate(action:(store:IDBObjectStore)=>unknown): Promise<void> {
    const db = await this.open();
    try { await new Promise<void>((resolve,reject) => {
      const tx = db.transaction('pending','readwrite'); action(tx.objectStore('pending'));
      tx.oncomplete = () => resolve(); tx.onerror = () => reject(tx.error); tx.onabort = () => reject(tx.error);
    }); } finally { db.close(); }
  }
}

function validatePending(pending: Pending): void {
  if (!pending || typeof pending.scope !== 'string' || !pending.scope || pending.id !== pending.command?.clientKey
      || typeof pending.createdAt !== 'string' || !Number.isFinite(Date.parse(pending.createdAt))) throw new Error('storage_invalid');
  if(pending.needsReview!==undefined && (pending.needsReview!==true || pending.command.kind!=='request.edit'))throw new Error('storage_invalid');
  validateOwnCommand(pending.command);
}
