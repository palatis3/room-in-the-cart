import {chromium} from '../../web/node_modules/playwright-core/index.mjs';
import fs from 'node:fs';
import assert from 'node:assert/strict';
const dir='.build/AndroidChromeUpdate20261106';
const {port}=JSON.parse(fs.readFileSync(`${dir}/cdp-forward.json`));
const browser=await chromium.connectOverCDP(`http://127.0.0.1:${port}`,{timeout:15000});
const pages=browser.contexts().flatMap(c=>c.pages()).filter(p=>p.url()==='https://room-in-the-cart-staging.vercel.app/help?lang=es');
assert.equal(pages.length,1,'Use only the task public tab');const page=pages[0];page.setDefaultTimeout(10000);
const errors=[];page.on('pageerror',e=>errors.push({type:'pageerror',message:e.message}));page.on('console',e=>{if(['warning','error'].includes(e.type()))errors.push({type:e.type(),message:e.text()});});
const observations=[];
try {
 for(const language of ['es','en']) {
  if(language==='en') {
   await page.getByRole('link',{name:'Room in the Cart',exact:true}).click();
   await page.getByRole('heading',{name:'Ayuda',exact:true,level:1}).waitFor();
   await page.locator('#public-language').selectOption('en');
  }
  const routes=language==='es'?[['help','Ayuda'],['privacy','Privacidad y datos'],['terms','Términos de uso'],['support','Soporte']]:[['help','Help'],['privacy','Privacy and data'],['terms','Terms of use'],['support','Support']];
  for(const [route,heading] of routes) {
   if(route!=='help') await page.getByRole('link',{name:heading,exact:true}).click();
   await page.getByRole('heading',{name:heading,exact:true,level:1}).waitFor();
   const observation=await page.evaluate(()=>({url:location.href,language:document.documentElement.lang,width:innerWidth,scrollWidth:document.documentElement.scrollWidth,height:innerHeight,dpr:devicePixelRatio,heading:document.querySelector('h1')?.textContent,contactLinks:[...document.querySelectorAll('a[href^="mailto:"]')].map(a=>a.getAttribute('href')),publicLinks:[...document.querySelectorAll('a[href^="/help"],a[href^="/privacy"],a[href^="/terms"],a[href^="/support"]')].map(a=>a.getAttribute('href'))}));
   assert.equal(new URL(observation.url).pathname,`/${route}`);assert.equal(new URL(observation.url).searchParams.get('lang'),language);assert.equal(observation.language,language);assert.ok(observation.scrollWidth<=observation.width,'No horizontal overflow');
   assert.ok(observation.publicLinks.every(h=>new URL(h,observation.url).searchParams.get('lang')===language),'Public links preserve language');
   if(route==='support')assert.ok(observation.contactLinks.includes('mailto:hello@roominthecart.com'));
   await page.screenshot({path:`${dir}/${route}-${language}-viewport.png`});observations.push(observation);
   fs.writeFileSync(`${dir}/public-walkthrough.json`,JSON.stringify({browser:browser.version(),observations,errors,complete:false},null,2)+'\n');
  }
 }
 const anchor=page.locator('a[href="#public-section-0"]');await anchor.click();
 await page.waitForFunction(()=>{const r=document.getElementById('public-section-0')?.getBoundingClientRect();return r&&r.top>=0&&r.top<innerHeight;});
 const section=await page.evaluate(()=>({hash:location.hash,top:document.getElementById('public-section-0').getBoundingClientRect().top,heading:document.getElementById('public-section-0').querySelector('h2')?.textContent}));
 await page.screenshot({path:`${dir}/support-en-section.png`});
 assert.equal(section.hash,'#public-section-0');
 fs.writeFileSync(`${dir}/public-walkthrough.json`,JSON.stringify({browser:browser.version(),observations,section,errors,complete:true,scope:'Eight rendered public pages on the actual Android emulator browser, same primed browser; no authentication/provider/device acceptance.'},null,2)+'\n');
 console.log(JSON.stringify({pages:observations.length,browser:browser.version(),widths:[...new Set(observations.map(v=>v.width))],errors,section}));
 process.exit(0);
} catch(error) {
 fs.writeFileSync(`${dir}/public-walkthrough-failure.json`,JSON.stringify({message:error.message,observations,errors},null,2)+'\n');console.error(error.message);process.exit(1);
}
