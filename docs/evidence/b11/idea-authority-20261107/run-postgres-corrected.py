import subprocess,json,os,socket,time,hashlib,tempfile
from pathlib import Path
repo=Path.cwd();base=repo/'.build/S26AcceptanceInvestigation20261107';root=base/'postgres-run-corrected';root.mkdir(mode=0o700,exist_ok=False);data=root/'data';socketdir=Path(tempfile.mkdtemp(prefix='ritc-s26-',dir='/tmp'));os.chmod(socketdir,0o700)
pgbin=repo/'.tools/postgres/bin';node=repo/'.tools/node-v22.23.4-darwin-arm64/bin/node'
def save(n,v):(root/n).write_text(json.dumps(v,indent=2)+'\n')
def run(label,cmd,env=None,stdin=None):
 save(label+'-invocation.json',{'command':[str(x) for x in cmd],'start':time.time(),'scope':'Dedicated synthetic loopback PostgreSQL cluster only'})
 with (root/(label+'.log')).open('w') as log:
  r=subprocess.run(cmd,env=env,input=stdin,text=True,stdout=log,stderr=subprocess.STDOUT)
 save(label+'-result.json',{'exit':r.returncode,'end':time.time()});print(label,r.returncode,flush=True);return r.returncode
with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
admin=f'postgresql://ritc_fixture_admin@127.0.0.1:{port}/ritc_acceptance';runtime=f'postgresql://ritc_runtime@127.0.0.1:{port}/ritc_acceptance'
env={**os.environ,'TEST_ADMIN_DATABASE_URL':admin,'TEST_DATABASE_URL':runtime,'MIGRATION_DATABASE_URL':admin,'PATH':str(node.parent)+os.pathsep+os.environ['PATH']}
assert run('initdb',[pgbin/'initdb','-D',data,'-A','trust','-U','ritc_fixture_admin','--no-locale'])==0
with (data/'postgresql.conf').open('a') as f:f.write("\nlisten_addresses = '127.0.0.1'\nport = "+str(port)+"\nunix_socket_directories = '"+str(socketdir).replace("'","''")+"'\n")
started=False
try:
 assert run('start',[pgbin/'pg_ctl','-D',data,'-l',root/'server.log','-w','start'])==0;started=True
 assert run('createdb',[pgbin/'createdb','-h','127.0.0.1','-p',str(port),'-U','ritc_fixture_admin','ritc_acceptance'])==0
 assert run('auth-schema',[pgbin/'psql',admin,'-v','ON_ERROR_STOP=1'],stdin='CREATE SCHEMA auth; CREATE TABLE auth.users(id uuid PRIMARY KEY,email text,email_confirmed_at timestamptz); CREATE TABLE auth.sessions(id uuid PRIMARY KEY,user_id uuid NOT NULL,not_after timestamptz);')==0
 assert run('migrations',[node,repo/'service/scripts/migrate.mjs'],env)==0
 assert run('runtime-role',[pgbin/'psql',admin,'-v','ON_ERROR_STOP=1'],stdin='CREATE ROLE ritc_runtime LOGIN NOSUPERUSER NOBYPASSRLS; GRANT ritc_app TO ritc_runtime;')==0
 save('database-identity.json',{'host':'127.0.0.1','port':port,'database':'ritc_acceptance','dataDirectory':str(data),'admin':'ritc_fixture_admin','runtime':'ritc_runtime','syntheticOnly':True,'socketDirectory':str(socketdir),'setupCorrection':'Initial cluster startup failed before tests: macOS Unix socket path exceeded103bytes; short private directory used here'})
 files=[repo/'service/tests/shared-meal-ideas.integration.mjs',*sorted((repo/'service/src').rglob('*.ts')),*sorted((repo/'service/migrations').glob('*.sql')),*sorted((repo/'service/dist').rglob('*.js'))]
 save('source-manifest.json',{str(p.relative_to(repo)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files})
 code=run('integration',[node,'--test','--test-concurrency=1',repo/'service/tests/shared-meal-ideas.integration.mjs'],env)
 assert run('final-identity',[pgbin/'psql',admin,'-At','-c',"SELECT current_database(),current_user,inet_server_addr(),inet_server_port(); SELECT rolname,rolsuper,rolbypassrls FROM pg_roles WHERE rolname='ritc_runtime'; SELECT count(*) FROM public.ritc_schema_migration;"])==0
 save('execution-complete.json',{'integrationExit':code,'sourceFiles':len(files),'scope':'Real PostgreSQL + local HTTP + synthetic identity/billing; no live provider or hosted database'})
finally:
 if started:assert run('stop',[pgbin/'pg_ctl','-D',data,'-m','fast','-w','stop'])==0
 if socketdir.exists():socketdir.rmdir()
