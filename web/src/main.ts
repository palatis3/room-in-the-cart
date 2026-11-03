import { WebApp } from './app.js';
import { consumeInvitation } from './api.js';
import './theme.css';
import './style.css';
const token=consumeInvitation(window.location,window.history);
const root=document.getElementById('app');
if(root) {
  const app=new WebApp(root,undefined,undefined,token);
  void app.start();
  window.setInterval(()=>app.checkExpiry(),1000);
  window.addEventListener('online',()=>void app.start());
  document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible')void app.start();});
}
