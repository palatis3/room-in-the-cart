from pathlib import Path, PurePosixPath
from datetime import datetime,timezone
import stat,base64,hashlib,io,json,subprocess,shutil,zipfile,urllib.request,urllib.error,re,sqlite3
B=Path('.build/CIF90Nov07/balanced-03-inspection')
R=B/'diagnostics-scope';R.mkdir()
a=json.loads((B/'artifact-metadata.json').read_text())
assert a['id']==13599104299 and a['workflow_run']['id']==42428215965 and a['workflow_run']['head_sha']=='f90ad75a2e561891b2014ecb234d19639bcaed4c'
assert a['name']=='iphone-fixture-results-contributor-balanced-03-1' and a['size_in_bytes']==54480673 and a['digest']=='sha256:6dd0afced63ef9b8781e4f87f8f184e3b42619fb4bae88949ff27340ca9403d4'
def save(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
def h(p):return hashlib.sha256(p.read_bytes()).hexdigest()
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None
token = subprocess.check_output([".tools/github-cli/bin/gh", "auth", "token"], text=True).strip()
req = urllib.request.Request(
    f"https://api.github.com/repos/palatis3/room-in-the-cart/actions/artifacts/{a['id']}/zip",
    headers={"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
             "User-Agent": "read-only-ci-evidence"})
try:
    response = urllib.request.build_opener(NoRedirect).open(req, timeout=45)
    response.close()
    raise RuntimeError("Expected artifact redirect")
except urllib.error.HTTPError as error:
    assert error.code == 302
    location = error.headers["Location"]
    error.close()
del token
ranges = R / "transport-ranges"
ranges.mkdir()
requests = []

class RemoteZip(io.RawIOBase):
    def __init__(self, size):
        self.size, self.pos, self.total, self.cache = size, 0, 0, {}
    def readable(self): return True
    def seekable(self): return True
    def tell(self): return self.pos
    def seek(self, offset, whence=0):
        self.pos = offset if whence == 0 else self.pos + offset if whence == 1 else self.size + offset
        assert 0 <= self.pos <= self.size
        return self.pos
    def read(self, n=-1):
        n = self.size - self.pos if n < 0 else min(n, self.size - self.pos)
        if not n: return b""
        assert n < 5_000_000 and self.total + n < 40_000_000, "Range budget refused"
        start, end = self.pos, self.pos + n - 1
        if (start, end) not in self.cache:
            req = urllib.request.Request(location, headers={"Range": f"bytes={start}-{end}"})
            with urllib.request.urlopen(req, timeout=45) as response:
                assert response.status == 206, "Range not honored; full body not read"
                match = re.fullmatch(r"bytes (\d+)-(\d+)/(\d+)", response.headers["Content-Range"])
                assert match and tuple(map(int, match.groups())) == (start, end, self.size)
                data = response.read(n + 1)
                assert len(data) == n
            self.total += n
            name = f"{len(requests)+1:04}.bin"
            (ranges / name).write_bytes(data)
            requests.append({"file": name, "start": start, "end": end, "bytes": n,
                             "sha256": hashlib.sha256(data).hexdigest()})
            save(R / "range-progress.json", {"requests": requests, "totalBytes": self.total})
            self.cache[start, end] = data
        data = self.cache[start, end]
        self.pos += n
        return data

remote = RemoteZip(a["size_in_bytes"])
original=[]
with zipfile.ZipFile(remote) as z:
    entries=z.infolist();assert len(entries)==len(set(z.namelist())) and len(entries)<50000
    def fetch(ref,maxBytes=100000):
        for prefix in ['data.','refs.']:
            name='Tests.xcresult/Data/'+prefix+ref;e=z.getinfo(name)
            p=PurePosixPath(name);assert not p.is_absolute() and '..' not in p.parts and '\\' not in name
            assert not e.flag_bits&1 and stat.S_IFMT(e.external_attr>>16) in (0,stat.S_IFREG)
            assert e.file_size<maxBytes and e.file_size<=max(e.compress_size,1)*1000
            dest=B/'pristine-members'/name
            if dest.exists():continue
            dest.parent.mkdir(parents=True,exist_ok=True);digest=hashlib.sha256();n=0
            with z.open(e) as src,dest.open('xb') as out:
                while True:
                    b=src.read(1024*1024)
                    if not b:break
                    n+=len(b);assert n<=e.file_size;digest.update(b);out.write(b)
            assert n==e.file_size
            cp=B/'inspection-copy'/name;cp.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(dest,cp)
            original.append({'file':name,'bytes':n,'sha256':digest.hexdigest(),'zipCRC':e.CRC,'CRCVerified':True})
    def refs(ref):
        raw=(B/'pristine-members/Tests.xcresult/Data'/('refs.'+ref)).read_bytes();pos=0
        def varint():
            nonlocal pos
            value=0;shift=0
            while True:
                v=raw[pos];pos+=1;value|=(v&127)<<shift
                if v<128:return value
                shift+=7;assert shift<63
        count=varint();values=[]
        for _ in range(count):
            n=varint();blob=raw[pos:pos+n];pos+=n
            assert len(blob)==65 and blob[0]==0
            values.append('0~'+base64.urlsafe_b64encode(blob[1:]).decode())
        assert pos==len(raw)
        return values
    def export(ref,path):
        p=subprocess.run(['xcrun','xcresulttool','export','object','--legacy','--path',str(B/'inspection-copy/Tests.xcresult'),'--id',ref,'--type','file','--output-path',str(path)],capture_output=True)
        save(path.with_suffix(path.suffix+'.receipt.json'),{'id':ref,'exit':p.returncode,'stderr':p.stderr.decode()});assert p.returncode==0
    meta=json.loads((B/'failed-case-sqlite-metadata.json').read_text());ref=meta['diagnosticsRefs'][0]['diagnosticsRef'];traversal=[]
    for level in range(3):
        fetch(ref);out=R/('directory-'+str(level)+'.json');export(ref,out)
        entries=json.loads(out.read_text());ids=refs(ref);assert len(entries)==len(ids)
        traversal.append({'directoryRef':ref,'entries':[{**x,'id':i} for x,i in zip(entries,ids)]})
        if level<2:
            chosen=[i for x,i in zip(entries,ids) if x['type']==2 and x['name'].startswith('RoomInTheCartUITests-')]
            assert len(chosen)==1;ref=chosen[0]
        else:
            sessions=[(x,i) for x,i in zip(entries,ids) if x['name'].startswith('Session-') and x['name'].endswith('.log')]
            assert len(sessions)==1,sessions
            item,ref=sessions[0]
    save(R/'directory-traversal.json',traversal)
    fetch(ref,32_000_000);log=R/'session-private.log';export(ref,log)
    save(R/'session-receipt.json',{'case':meta['caseURL'],'sourceFile':item['name'],'sourceBytes':log.stat().st_size,'sourceSHA256':h(log)})
save(R/'pristine-download-manifest.json',original)
save(R/'range-receipt.json',{'artifactID':13599104299,'requests':requests,'totalBytes':remote.total,'fullArchiveDownloaded':False,'fullArchiveAPIHashVerified':False,'scope':'Declared diagnostic directory metadata and one exact-invocation XCTest Session log only.'})
print(json.dumps({'session':item['name'],'sessionBytes':log.stat().st_size,'rangeBytes':remote.total}))
