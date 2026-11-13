import copy
import unittest
from correlate import analyze, unique_object
import json

def fixture():
    events=[]; endpoints=[]; windows=[]
    for i in range(6):
        start=100+i*10
        stamp=lambda t:{'absoluteTime':str(t*1000000000),'absoluteTimeNanoSeconds':str(t*1000000000),'unixSeconds':float(t)}
        for kind in ('created','willBegin','didStop','report'):
            event={'sequence':len(events)+1,'instanceOrdinal':str(i+1),'kind':kind,'callbackUptime':float(len(events)),'callbackUnixUTC':1000.+len(events)}
            if kind=='report':event.update(suppliedStart=stamp(start),suppliedEnd=stamp(start+5))
            events.append(event)
        windows.append({'invocationIndex':i,'swipeStartOffsetSeconds':i*10+1,'synthesisStartOffsetSeconds':i*10+2,'followingActivityStartOffsetSeconds':i*10+6})
        for off,kind in ((2,'begin'),(4,'end')):
            endpoints.append({'offsetSeconds':i*10+off,'kind':kind,'processToken':'process-1','signpostToken':'signpost-'+str(i),'windowIndices':[i]})
    w={'schemaVersion':1,'diagnosticOnly':True,'status':'recorded','omittedEvents':0,'events':events,'totalEvents':24,'maximumRetainedEvents':128,'totalInstances':'6','reportCallbacks':6}
    d={'schemaVersion':2,'diagnosticOnly':True,'captureStatus':'ok','activityStatus':'ok','status':'captured','unparsedCandidateCount':0,'matchedProcessCount':1,'endpointEvidence':{'diagnosticOnly':True,'status':'retained','omittedEventCount':0,'originUnixUTC':100,'scopeStartOffsetSeconds':-5,'scopeEndOffsetSeconds':60,'events':endpoints,'retainedEventCount':12,'scopedEventCount':12,'windows':windows}}
    return w,d

class CorrelationTests(unittest.TestCase):
    def test_valid_is_only_observation(self):
        r=analyze(*fixture());self.assertEqual(r['status'],'observations-only');self.assertEqual(len(r['reports']),6)
        self.assertTrue(all(x['numericallyContained'] for x in r['reports']))
    def test_started_instance_without_report(self):
        w,d=fixture()
        for kind in ('created','willBegin','didStop'):
            w['events'].append({'sequence':len(w['events'])+1,'instanceOrdinal':'7','kind':kind,'callbackUptime':500.,'callbackUnixUTC':1500.})
        w['totalEvents']=27;w['totalInstances']='7'
        self.assertEqual(analyze(w,d)['status'],'needs-review')
    def test_unused_created_instance_is_explicit(self):
        w,d=fixture();w['events'].append({'sequence':25,'instanceOrdinal':'7','kind':'created','callbackUptime':500.,'callbackUnixUTC':1500.});w['totalEvents']=25;w['totalInstances']='7'
        r=analyze(w,d);self.assertEqual(r['status'],'observations-only');self.assertEqual(r['instancesWithoutReports'],[{'instanceOrdinal':'7','lifecycle':['created']}])
    def test_callback_clock_missing(self):
        w,d=fixture();del w['events'][0]['callbackUptime'];self.assertEqual(analyze(w,d)['status'],'unavailable')
    def test_endpoint_indices_wrong(self):
        w,d=fixture();d['endpointEvidence']['events'][0]['windowIndices']=[];self.assertEqual(analyze(w,d)['status'],'unavailable')
    def test_contradictory_process_count(self):
        w,d=fixture()
        for event in d['endpointEvidence']['events'][:2]:event['processToken']='process-2'
        self.assertEqual(analyze(w,d)['status'],'unavailable')
    def test_duplicate_json_keys(self):
        with self.assertRaises(ValueError):json.loads('{"status":"bad","status":"recorded"}',object_pairs_hook=unique_object)
    def test_absent(self):self.assertEqual(analyze({}, {})['status'],'unavailable')
    def test_truncation(self):
        w,d=fixture();w['omittedEvents']=1;self.assertEqual(analyze(w,d)['status'],'unavailable')
    def test_nonfinite(self):
        w,d=fixture();w['events'][3]['suppliedStart']['unixSeconds']=float('nan');self.assertEqual(analyze(w,d)['status'],'unavailable')
    def test_reversed(self):
        w,d=fixture();w['events'][3]['suppliedEnd']=w['events'][3]['suppliedStart'];self.assertEqual(analyze(w,d)['status'],'unavailable')
    def test_clock_delta(self):
        w,d=fixture();w['events'][3]['suppliedEnd']['absoluteTimeNanoSeconds']='104000000000';self.assertEqual(analyze(w,d)['status'],'needs-review')
    def test_duplicate_reports(self):
        w,d=fixture();w['events'].append(copy.deepcopy(w['events'][3]));w['events'][-1]['sequence']=25;w['totalEvents']=25;w['reportCallbacks']=7
        self.assertEqual(analyze(w,d)['status'],'needs-review')
    def test_no_automatic_warmup(self):
        w,d=fixture();w['events']=w['events'][4:];w['totalEvents']=20;w['totalInstances']='5';w['reportCallbacks']=5
        for i,e in enumerate(w['events']):e['sequence']=i+1
        r=analyze(w,d);self.assertEqual(r['status'],'needs-review');self.assertEqual(r['unmatchedActivityIndices'],[0])
    def test_outside_pair_preserved(self):
        w,d=fixture();w['events'][3]['suppliedStart']['unixSeconds']=103.;w['events'][3]['suppliedStart']['absoluteTime']='103000000000';w['events'][3]['suppliedStart']['absoluteTimeNanoSeconds']='103000000000'
        r=analyze(w,d);self.assertFalse(r['reports'][0]['numericallyContained']);self.assertEqual(r['reports'][0]['endpointStartMarginSeconds'],-1.)
    def test_unparsed_or_truncated_endpoints(self):
        for key in ('unparsedCandidateCount','matchedProcessCount'):
            w,d=fixture();d[key]=2;self.assertEqual(analyze(w,d)['status'],'unavailable')
        w,d=fixture();d['endpointEvidence']['omittedEventCount']=1;self.assertEqual(analyze(w,d)['status'],'unavailable')
    def test_mismatched_tokens(self):
        w,d=fixture();d['endpointEvidence']['events'][1]['signpostToken']='different';self.assertEqual(analyze(w,d)['status'],'needs-review')
    def test_lifecycle_missing(self):
        w,d=fixture();w['events'][1]['kind']='didStop';self.assertEqual(analyze(w,d)['status'],'needs-review')
    def test_ambiguous_overlap(self):
        w,d=fixture();w['events'][3]['suppliedEnd']={'unixSeconds':115.,'absoluteTime':'115000000000','absoluteTimeNanoSeconds':'115000000000'}
        self.assertEqual(analyze(w,d)['status'],'needs-review')

if __name__=='__main__':unittest.main()
