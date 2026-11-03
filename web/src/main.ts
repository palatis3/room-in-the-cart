import { WebApp } from './app.js';
import { consumeInvitation } from './api.js';
import './theme.css';
import './style.css';
import { mountPublicPage } from './public-pages.js';
import { mountChildInvitationPage } from './child-invitation-page.js';
import './public-pages.css';
const root=document.getElementById('app');
if(root && !mountPublicPage(root) && !mountChildInvitationPage(root)) {
  const token=consumeInvitation(window.location,window.history);
  const app=new WebApp(root,undefined,undefined,token);
  void app.start();
  window.setInterval(()=>app.checkExpiry(),1000);
  window.addEventListener('online',()=>void app.start());
  document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible')void app.start();});
}
