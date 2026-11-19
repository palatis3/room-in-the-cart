// A staffed operator uses an interactive true-color terminal. No original file,
// temporary preview, browser cache, or image payload is written to disk.
import {createInterface} from 'node:readline/promises';
import {pathToFileURL} from 'node:url';
import {Pool} from '../dist/database.js';
import {workerDatabaseConfiguration} from '../dist/operations-runtime.js';

export function reviewFrame({pixels,width,height,description},columns,rows){
  if(!Buffer.isBuffer(pixels)||!Number.isInteger(width)||!Number.isInteger(height)||
    width<8||height<8||width>192||height>192||pixels.length!==width*height*3)throw Error('Invalid crop.');
  // Remove terminal control, line breaks, and Unicode formatting/bidi instructions from untrusted wording.
  const wording=description.replace(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/gu,' ');
  const scale=Math.min(1,(columns-2)/width,2*(rows-8)/height);
  if(scale<=0)throw Error('Enlarge the terminal and reopen the review.');
  const w=Math.max(1,Math.floor(width*scale)),h=Math.max(1,Math.floor(height*scale));
  const color=(x,y)=>{
    const i=(Math.floor(Math.min(y,h-1)*height/h)*width+Math.floor(x*width/w))*3;
    return pixels[i]+';'+pixels[i+1]+';'+pixels[i+2];
  };
  let frame=wording+'\n';
  for(let y=0;y<h;y+=2){
    for(let x=0;x<w;x++)frame+='\x1b[38;2;'+color(x,y)+'m\x1b[48;2;'+color(x,y+1)+'m▀';
    frame+='\x1b[0m\n';
  }
  return frame;
}

// The expiry timer is independent of the database probe, including a stalled connection.
// Losing the ticket closes the whole prompt so partially typed input cannot decide a later image.
export async function reviewChoice({expiresAt,show,clear,ask,stillPending,pollMs=2000}){
  if(expiresAt<=Date.now())return;
  const controller=new AbortController();
  let poll,expired,closed=false;
  const close=()=>{
    if(closed)return;
    closed=true;
    clearTimeout(poll);clearTimeout(expired);
    controller.abort();clear();
  };
  const probe=async()=>{
    try{
      if(!await stillPending()){close();return;}
    }catch{close();return;}
    if(!closed)poll=setTimeout(probe,pollMs);
  };
  try{
    expired=setTimeout(close,Math.max(0,expiresAt-Date.now()));
    poll=setTimeout(probe,pollMs);
    show();
    const choice=await ask(controller.signal);
    if(!closed&&expiresAt>Date.now())return choice;
  }catch(error){if(!controller.signal.aborted)throw error;}
  finally{close();}
}

async function review(){
  if(!process.stdin.isTTY||!process.stdout.isTTY)throw Error('Use an interactive true-color terminal without output capture.');
  const url=process.env.PRODUCT_MEDIA_REVIEW_DATABASE_URL;
  if(!url)throw Error('Configure a dedicated PRODUCT_MEDIA_REVIEW_DATABASE_URL.');
  const pool=new Pool(workerDatabaseConfiguration({WORKER_DATABASE_URL:url,DATABASE_URL:process.env.DATABASE_URL,
    WORKER_DATABASE_CA_PEM:process.env.PRODUCT_MEDIA_REVIEW_CA_PEM}));
  const screen=process.stdout,rl=createInterface({input:process.stdin,output:screen});
  const restore=()=>screen.write('\x1b[0m\x1b[?1049l');
  try{
    const role=(await pool.query(`SELECT pg_has_role(current_user,'ritc_media_moderator','USAGE') AND current_user=session_user
      AND NOT rolsuper AND NOT rolbypassrls AND NOT has_table_privilege(current_user,'ritc.adult_product_reference','SELECT')
      AND NOT pg_has_role(current_user,'ritc_app','MEMBER') AND NOT pg_has_role(current_user,'ritc_worker','MEMBER') AS permitted
      FROM pg_roles WHERE rolname=current_user`)).rows[0];
    if(role?.permitted!==true)throw Error('Use a dedicated, unprivileged media moderator login.');
    screen.write('\x1b[?1049h');process.once('exit',restore);
    while(true){
      const row=(await pool.query('SELECT * FROM ritc.product_media_queue() LIMIT 1')).rows[0];
      if(!row)break;
      const choice=await reviewChoice({
        expiresAt:row.expires_at.getTime(),
        show:()=>{
          screen.write('\x1b[2J\x1b[H'+reviewFrame(row,screen.columns,screen.rows));
          if(row.reported)screen.write('The recipient reported this image. Review it again.\n');
          screen.write('Expires '+row.expires_at.toISOString()+'\n');
        },
        clear:()=>screen.write('\x1b[0m\x1b[2J\x1b[H'),
        ask:async signal=>(await rl.question('Type approve, reject or quit: ',{signal})).trim().toLowerCase(),
        stillPending:async()=>(await pool.query('SELECT ritc.product_media_pending($1) AS pending',[row.review_id])).rows[0]?.pending===true,
      });
      if(!choice||choice==='quit')break;
      if(choice!=='approve'&&choice!=='reject')continue;
      const result=(await pool.query('SELECT ritc.product_media_resolve($1,$2) AS saved',
        [row.review_id,choice==='approve'?'approved':'rejected'])).rows[0];
      if(!result?.saved)await rl.question('This publication changed or expired. Press Return to refresh.');
    }
  }finally{process.removeListener('exit',restore);restore();rl.close();await pool.end();}
}

if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
  review().catch(()=>{process.stderr.write('Media review closed. Verify the terminal, moderator credential and database availability.\n');process.exitCode=1;});
}
