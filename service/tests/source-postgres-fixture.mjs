// Both permitted endpoints are disposable, local PostgreSQL fixtures. The hosted
// CI service has a fixed loopback address, owner and known fixture-only password.
export function sourceFixtureConnection(url,user=url.username,database=url.pathname.slice(1)){
 if(['localhost','127.0.0.1'].includes(url.hostname)&&url.searchParams.get('host')==='/tmp'&&url.searchParams.get('port')==='55432'){
  return {host:'/tmp',port:55432,user,database};
 }
 if(process.env.GITHUB_ACTIONS==='true'&&url.protocol==='postgresql:'&&url.hostname==='127.0.0.1'&&url.port==='5432'&&url.username==='postgres'&&url.password==='fixture-only'&&!url.search&&!url.hash){
  return {host:'127.0.0.1',port:5432,user,database,password:'fixture-only'};
 }
 throw Error('Only the local Unix socket or the isolated CI fixture is permitted');
}
