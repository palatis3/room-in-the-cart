from pathlib import Path, PurePosixPath
import hashlib,io,json,subprocess,shutil,stat,zipfile,urllib.request,urllib.error,re,sqlite3,plistlib
R=Path('.build/CIF90Nov07/balanced-03-inspection/attachment-download');R.mkdir()
a=json.loads(Path('.build/CIF90Nov07/balanced-03/artifact-metadata.json').read_text())
assert a['id']==13599104299 and a['workflow_run']['id']==42428215965 and a['workflow_run']['head_sha']=='f90ad75a2e561891b2014ecb234d19639bcaed4c'
assert a['name']=='iphone-fixture-results-contributor-balanced-03-1' and a['size_in_bytes']==54480673 and a['digest']=='sha256:6dd0afced63ef9b8781e4f87f8f184e3b42619fb4bae88949ff27340ca9403d4'
def save(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
def h(p):return hashlib.sha256(p.read_bytes()).hexdigest()
save(R/'artifact-metadata.json',a)
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
        assert n < 5_000_000 and self.total + n < 12_000_000, "Range budget refused"
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
            self.cache[start, end] = data
        data = self.cache[start, end]
        self.pos += n
        return data

remote=RemoteZip(a['size_in_bytes'])
P=R/'pristine-members';P.mkdir();C=R.parent/'inspection-copy';manifest=[]
meta=json.loads((R.parent/'failed-case-sqlite-metadata.json').read_text())
chosen=[x for x in meta['caseAttachments'] if x['name'] in ['S24-request-pack-failure','S24-failure-accessibility-hierarchy','S24-failure-preview-diagnostics']]
assert len(chosen)==3
ids={6574}
for _ in range(10):ids.update(x['rowid'] for x in meta['activities'] if x['parent_fk'] in ids)
chosen += [x for x in meta['caseAttachments'] if x['activity_fk'] in ids]
with zipfile.ZipFile(remote) as z:
    entries=z.infolist();assert len(entries)==len(set(z.namelist())) and len(entries)<50000
    def extract(name):
        e=z.getinfo(name);p=PurePosixPath(name)
        assert not p.is_absolute() and '..' not in p.parts and '\\' not in name
        assert not e.flag_bits&1 and stat.S_IFMT(e.external_attr>>16) in (0,stat.S_IFREG)
        assert e.file_size<5_000_000 and e.file_size<=max(e.compress_size,1)*1000
        raw=z.read(e);out=P/p;out.parent.mkdir(parents=True,exist_ok=True);out.write_bytes(raw)
        cp=C/p;cp.parent.mkdir(parents=True,exist_ok=True)
        if cp.exists():assert cp.read_bytes()==raw
        else:shutil.copy2(out,cp)
        manifest.append({'file':name,'bytes':len(raw),'sha256':h(out),'zipCRC':e.CRC,'CRCVerified':True})
    outdir=R/'exports';outdir.mkdir();receipts=[]
    for row in chosen:
        ref=row['xcResultKitPayloadRefId'];extract('Tests.xcresult/Data/data.'+ref)
        key='Tests.xcresult/Data/refs.'+ref
        if key in z.namelist():extract(key)
        name=row['name']+('.png' if row['uniformTypeIdentifier']=='public.png' else '.txt' if row['uniformTypeIdentifier']=='public.plain-text' else '.snapshot')
        out=outdir/name
        p=subprocess.run(['xcrun','xcresulttool','export','object','--legacy','--path',str(C/'Tests.xcresult'),'--id',ref,'--type','file','--output-path',str(out)],capture_output=True)
        receipts.append({'attachment':row,'file':str(out.relative_to(R)),'exit':p.returncode,'stderr':p.stderr.decode(),'bytes':out.stat().st_size if out.exists() else None,'sha256':h(out) if out.exists() else None})
    save(R/'export-receipts.json',receipts);assert all(x['exit']==0 for x in receipts)
save(R/'pristine-manifest.json',manifest)
save(R/'range-receipt.json',{'artifactID':13599104299,'transferredBytes':remote.total,'requests':requests,'fullArchiveDownloaded':False,'fullArchiveAPIHashVerified':False,'scope':'Only exact failed-case teardown screenshot, hierarchy, diagnostics and matched-switch tap attachments; no video or other-case payload.'})
print(json.dumps({'exports':[{'name':x['attachment']['name'],'exit':x['exit'],'bytes':x['bytes']} for x in receipts],'rangeBytes':remote.total}))
