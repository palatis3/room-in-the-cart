import {connect,type TLSSocket} from 'node:tls';
import {createInterface} from 'node:readline';
import {once} from 'node:events';

// Resend accepts the same domain-scoped sending key for implicit-TLS SMTP.
// Authenticate and quit without an envelope, recipient or message.
export async function checkSenderSession(
  lines:AsyncIterator<string>,write:(command:string)=>void,key:string
):Promise<boolean>{
  async function reply(expected:number){
    const result:string[]=[];
    for(let line=0;line<32;line++){
      const entry=await lines.next();
      if(entry.done||entry.value.length>2048)throw Error('Invalid mail server reply');
      const match=/^(\d{3})([- ])(.*)$/.exec(entry.value);
      if(!match||Number(match[1])!==expected)throw Error('Mail server did not confirm status');
      result.push(match[3]!);
      if(match[2]===' ')return result;
    }
    throw Error('Unbounded mail server reply');
  }
  await reply(220);
  write('EHLO roominthecart.com');
  if(!(await reply(250)).some(line=>/^AUTH[ =]/i.test(line)&&/\bPLAIN\b/i.test(line)))return false;
  write('AUTH PLAIN '+Buffer.from('\0resend\0'+key).toString('base64'));
  await reply(235);
  write('QUIT');
  return true;
}

export async function probeRenewalSender(key:string,signal:AbortSignal):Promise<boolean>{
  const limit=AbortSignal.any([signal,AbortSignal.timeout(2500)]);
  let socket:TLSSocket|undefined;
  const close=()=>socket?.destroy();
  try{
    limit.throwIfAborted();
    socket=connect({host:'smtp.resend.com',port:465,servername:'smtp.resend.com',minVersion:'TLSv1.2',rejectUnauthorized:true});
    limit.addEventListener('abort',close,{once:true});
    const ready=once(socket,'secureConnect',{signal:limit});
    const reader=createInterface({input:socket,crlfDelay:Infinity});
    const lines=reader[Symbol.asyncIterator]();
    try{
      await ready;
      return await checkSenderSession(lines,command=>socket!.write(command+'\r\n'),key);
    }finally{reader.close();}
  }catch{return false;}finally{limit.removeEventListener('abort',close);close();}
}
