import { WebApp } from './app.js';
import { consumeInvitation } from './api.js';
import './theme.css';
import './style.css';
import { mountPublicPage } from './public-pages.js';
import { mountChildInvitationPage } from './child-invitation-page.js';
import { browserSignOutKey } from './browser-sign-out.js';
import './public-pages.css';
const root=document.getElementById('app');
if(root && !mountPublicPage(root) && !mountChildInvitationPage(root)) {
  const token=consumeInvitation(window.location,window.history);
  const app=new WebApp(root,undefined,undefined,token);
  void app.start();
  window.setInterval(()=>app.checkExpiry(),1000);
  window.addEventListener('pagehide',()=>app.suspendForHistory());
  window.addEventListener('pageshow',event=>{if(event.persisted)app.resumeFromHistory();});
  window.addEventListener('online',()=>void app.start());
  window.addEventListener('storage',event=>{if(event.key===browserSignOutKey&&event.newValue==='1')void app.start();});
  document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible')void app.start();});
}
