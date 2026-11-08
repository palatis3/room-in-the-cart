from pathlib import Path, PurePosixPath
import hashlib,io,json,subprocess,shutil,stat,zipfile,urllib.request,urllib.error,re,sqlite3,plistlib
R=Path('.build/CIF90Nov07/balanced-03-inspection');R.mkdir()
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

remote = RemoteZip(a["size_in_bytes"])
P=R/'pristine-members';P.mkdir()
C=R/'inspection-copy';C.mkdir()
manifest=[]
with zipfile.ZipFile(remote) as z:
    entries=z.infolist();assert len(entries)==len(set(z.namelist())) and len(entries)<50000
    def extract(name):
        e=z.getinfo(name);p=PurePosixPath(name)
        assert not p.is_absolute() and '..' not in p.parts and '\\' not in name
        assert not e.flag_bits&1 and stat.S_IFMT(e.external_attr>>16) in (0,stat.S_IFREG)
        assert e.file_size<5_000_000 and e.file_size<=max(e.compress_size,1)*1000
        raw=z.read(e);out=P/p;out.parent.mkdir(parents=True,exist_ok=True);out.write_bytes(raw)
        cp=C/p;cp.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(out,cp)
        manifest.append({'file':name,'bytes':len(raw),'sha256':h(out),'zipCRC':e.CRC,'CRCVerified':True})
        return cp
    for name in ['Tests.xcresult/Info.plist','Tests.xcresult/database.sqlite3']:
        extract(name)
    root=plistlib.loads((P/'Tests.xcresult/Info.plist').read_bytes())['rootId']['hash']
    for prefix in ['data.','refs.']:extract('Tests.xcresult/Data/'+prefix+root)
    db=(P/'Tests.xcresult/database.sqlite3').resolve();c=sqlite3.connect('file:'+str(db)+'?mode=ro',uri=True);c.row_factory=sqlite3.Row
    caseURL='test://com.apple.xcode/RoomInTheCart/RoomInTheCartUITests/HouseholdRequestPackUITests/testReviewedCheapestAvailablePackUsesActualDecisionAndCancelHasNoWrite'
    cases=c.execute('SELECT rowid,* FROM TestCases WHERE identifierURL=?',(caseURL,)).fetchall();assert len(cases)==1
    runs=c.execute('SELECT rowid,* FROM TestCaseRuns WHERE testCase_fk=?',(cases[0]['rowid'],)).fetchall();assert len(runs)==1
    rid=runs[0]['rowid']
    acts=[dict(x) for x in c.execute('WITH RECURSIVE scope(id) AS (SELECT rowid FROM Activities WHERE testCaseRun_fk=? UNION SELECT a.rowid FROM Activities a JOIN scope ON a.parent_fk=scope.id) SELECT rowid,* FROM Activities WHERE rowid IN scope ORDER BY startTime,orderInParent',(rid,))]
    ids={x['rowid'] for x in acts}
    att=[dict(x) for x in c.execute('SELECT rowid,* FROM Attachments') if x['activity_fk'] in ids]
    meta={'caseURL':caseURL,'case':dict(cases[0]),'run':dict(runs[0]),'activities':acts,'caseAttachments':att,'diagnosticsRefs':[dict(x) for x in c.execute('SELECT diagnosticsRef FROM Actions')],'toolchain':[dict(x) for x in c.execute('SELECT * FROM DeveloperTools')],'timeBasis':'CFAbsoluteTime since2001, plus978307200 for Unix epoch.'}
    save(R/'failed-case-sqlite-metadata.json',meta)
save(R/'pristine-manifest.json',manifest)
save(R/'range-receipt.json',{'artifactID':13599104299,'transferredBytes':remote.total,'requests':requests,'fullArchiveDownloaded':False,'fullArchiveAPIHashVerified':False,'scope':'Only Info.plist/SQLite/root metadata; no media or diagnostics payload.'})
print(json.dumps({'attachmentCount':len(att),'rangeBytes':remote.total}))
