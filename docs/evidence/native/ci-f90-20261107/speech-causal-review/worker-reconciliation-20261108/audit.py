"""Offline audit of retained files only; no tools, bundle access, or execution of Swift."""
import hashlib,json,struct,uuid
from datetime import datetime
from pathlib import Path
P=Path(__file__).resolve().parent

def decode(e):
    detail, payload=e['eventMessage'].split("}'",1)
    detail=json.loads(detail.split('__message__:',1)[1]+'}')
    raw=bytes.fromhex(payload.split("'",1)[0])
    assert len(raw)%20==0
    frames=[{'uuid':str(uuid.UUID(bytes=u)).upper(),'offset':hex(o)} for u,o in struct.iter_unpack('<16sI',raw)]
    return {'timestamp':e['timestamp'],'pid':e['processID'],'emissionThreadID':e['threadID'],'processImageUUID':e['processImageUUID'],'detail':detail,'blockedStack':frames}

def sig(frames):return tuple((f['uuid'],f['offset']) for f in frames[:6])

def main():
    foreground=json.loads((P/'foreground-qos.json').read_text()); aggregate=json.loads((P/'background-qos.json').read_text())
    assert len(foreground)==5 and len(aggregate)==10 and aggregate[:5]==foreground
    fore=[decode(e) for e in foreground]; worker=[decode(e) for e in aggregate[5:]]
    assert {e['pid'] for e in fore}=={70394}
    assert {e['pid'] for e in worker}=={70758}
    assert {e['emissionThreadID'] for e in worker}=={22684028}
    begin=datetime.fromisoformat('2026-11-07T12:24:25.167-05:00');end=datetime.fromisoformat('2026-11-07T12:24:34.427-05:00')
    for e in worker:assert begin<datetime.strptime(e['timestamp'], '%Y-%m-%d %H:%M:%S.%f%z')<end
    for e in fore:assert datetime.strptime(e['timestamp'], '%Y-%m-%d %H:%M:%S.%f%z')<begin
    f90=json.loads((P/'f90-decoded-stacks.json').read_text())['events']
    comparisons=[]
    for e in f90:
        s=sig(e['decodedBlockedStack'])
        comparisons.append({'f90Event':e['index'],'f90Timestamp':e['timestamp'],'firstSix':e['decodedBlockedStack'][:6],'foregroundMatches':[i for i,x in enumerate(fore) if sig(x['blockedStack'])==s],'workerMatches':[i for i,x in enumerate(worker) if sig(x['blockedStack'])==s]})
    assert [e['f90Event'] for e in comparisons if e['workerMatches']]==[0,1,3,4,5]
    assert comparisons[2]['foregroundMatches']==[1] and comparisons[2]['workerMatches']==[]
    assert len({sig(e['blockedStack']) for e in worker})==4
    elapsed=(datetime.strptime(worker[-1]['timestamp'], '%Y-%m-%d %H:%M:%S.%f%z')-datetime.strptime(worker[0]['timestamp'], '%Y-%m-%d %H:%M:%S.%f%z')).total_seconds()
    output={'schema':1,'status':'offline evidence reconciliation; not native qualification','foregroundPrefixExactlyDuplicated':True,'foregroundEventCount':5,'workerEventCount':5,'workerDistinctFirstSixSignatures':4,'workerNativeCaseStart':begin.isoformat(),'workerNativeCaseEnd':end.isoformat(),'workerFaultWindowSeconds':elapsed,'waitDurationSeconds':None,'durationLimit':'The event window and XCTest synthesis intervals are not wait or API-call durations. Raw events contain no wait duration or complete lower-priority-owner stack.','foreground':fore,'worker':worker,'f90FirstSixComparisons':comparisons,'claimCorrection':'Aggregate ten contains five earlier foreground records. Direct Pause signature matches only foreground, not the five scoped worker events. Absence in this capture is not proof of elimination.'}
    print(json.dumps(output,indent=2))
if __name__=='__main__':main()
