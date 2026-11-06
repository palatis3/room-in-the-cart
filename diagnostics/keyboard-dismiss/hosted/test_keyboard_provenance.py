import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from reconcile_keyboard_logs import capture_provenance, reconcile, read_file, main, SUBSYSTEM
from test_reconcile_keyboard_logs import event


class ProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)
    def write(self,name,value):
        (self.root/name).write_text(json.dumps(value))
    def receipts(self):
        self.owned={'name':'RITC keyboard run synthetic','runtime':'com.apple.CoreSimulator.SimRuntime.iOS-26-2','udid':'11111111-1111-4111-8111-111111111111'}
        self.window={'startUTC':'2026-11-06 12:00:00+0000'}
        self.write('owned-device.json',self.owned);self.write('capture-window.json',self.window)
        self.write('capture-liveness.json',{'ownerAliveBeforeStop':True})
        self.write('capture-owner-final.json',{'ownerReaped':True,'gracefulFinalizationConfirmed':True,
            'helperFinalReceiptPresent':True,'exitCode':0})
        self.write('capture-final.json',{'shutdownComplete':True,'helperExit':0})
        self.export={'argv':['xcrun','simctl','spawn','11111111-1111-4111-8111-111111111111','log','show','--start','2026-11-06 12:00:00+0000',
            '--end','2026-11-06 12:01:00+0000','--info','--style','compact','--timezone','UTC',
            '--predicate','subsystem == "'+SUBSYSTEM+'" AND category == "events"'],
            'status':'passed','exitCode':0,'stage':'events-export','timeoutSeconds':45,'stderrSeparate':True}
        self.write('events-export.status.json',self.export)
    def test_capture_finalization_and_exact_scope_are_hashed_not_exhaustiveness(self):
        self.receipts();p=capture_provenance(self.root)
        self.assertTrue(p['liveFinalizationVerified']);self.assertTrue(p['exportCommandScopeVerified'])
        self.assertTrue(p['exportCommandPassed']);self.assertEqual(p['liveWallTimeZone'],'unknown')
        self.assertEqual(p['exportWallTimeZone'],'UTC');self.assertFalse(p['exhaustiveDeliveryEstablished'])
        self.assertEqual(p['receiptSHA256']['events-export.status.json'],hashlib.sha256((self.root/'events-export.status.json').read_bytes()).hexdigest())
        for name in ('owned-device.json','capture-window.json'):
            self.assertEqual(p['receiptSHA256'][name],hashlib.sha256((self.root/name).read_bytes()).hexdigest())
        self.assertEqual(p['exportWindowSeconds'],60)
        self.assertNotIn('11111111-1111-4111-8111-111111111111',json.dumps(p))
    def test_forged_flag_types_failed_export_and_missing_receipts_never_prove_capture(self):
        self.receipts();self.write('capture-liveness.json',{'ownerAliveBeforeStop':1})
        self.export['exitCode']=65;self.export['status']='failed';self.write('events-export.status.json',self.export)
        p=capture_provenance(self.root);self.assertFalse(p['liveFinalizationVerified']);self.assertFalse(p['exportCommandPassed'])
        (self.root/'capture-final.json').unlink();self.assertIn('capture-final.json',capture_provenance(self.root)['missingOrInvalidReceipts'])
    def test_unknown_or_duplicate_timezone_predicate_and_window_refuse_scope_claim(self):
        self.receipts()
        for argv in [self.export['argv']+['--timezone','UTC'],
                     [v.replace('urgentkeyboarddiagnostic','other') for v in self.export['argv']],
                     [v.replace('+0000','') for v in self.export['argv']],
                     [v.replace('UTC','local') for v in self.export['argv']]]:
            self.write('events-export.status.json',{**self.export,'argv':argv})
            p=capture_provenance(self.root);self.assertFalse(p['exportCommandScopeVerified']);self.assertEqual(p['exportWallTimeZone'],'unknown')
    def test_receipts_drive_cli_metadata_without_promoting_delivery_or_native_acceptance(self):
        self.receipts();live=self.root/'live';export=self.root/'export';out=self.root/'out'
        live.write_text(event());export.write_text(event())
        argv=['reconcile','--live',str(live),'--export',str(export),'--capture-receipts-dir',str(self.root),'--output',str(out)]
        with patch('sys.argv',argv):self.assertEqual(main(),0)
        result=json.loads(out.read_text());self.assertEqual(result['sources']['export']['timezoneProvenance'],'captured_command_receipt')
        self.assertEqual(result['sources']['live']['wallTimeZone'],'unknown');self.assertEqual(result['status'],'inconclusive')
        self.assertFalse(result['negativeEventInferencePermitted']);self.assertNotIn('nativeAndStrictPassed',result)
    def test_uptime_regression_and_equal_time_do_not_invent_a_causal_outcome(self):
        rows='\n'.join([event(1,uptime='10'),event(2,'done.enter',uptime='10'),event(3,'done.exit',uptime='9')])
        r=reconcile(rows,'');self.assertEqual(r['sources']['live']['processes']['101']['uptimeRegressionsInInputOrder'],1)
        self.assertFalse(r['negativeEventInferencePermitted']);self.assertEqual(r['status'],'inconclusive')
    def test_bounded_log_read_refuses_oversize_without_echoing_contents(self):
        path=self.root/'log';path.write_text('private-content')
        with patch('reconcile_keyboard_logs.MAX_LOG_BYTES',5):self.assertEqual(read_file(path),('','unavailable',None))
    def test_invalid_read_metadata_rejected(self):
        with self.assertRaises(ValueError):reconcile('','',live_read='complete')

    def assert_scope_refused(self):
        value=capture_provenance(self.root)
        self.assertFalse(value['exportCommandScopeVerified']);self.assertFalse(value['exportCommandPassed'])
        self.assertEqual(value['exportWallTimeZone'],'unknown')
        self.assertEqual(value['timezoneProvenance'],'unknown')
        self.assertFalse(value['exhaustiveDeliveryEstablished'])

    def test_export_device_must_equal_owned_receipt_and_start_must_equal_capture_receipt(self):
        self.receipts();self.export['argv'][3]='22222222-2222-4222-8222-222222222222'
        self.write('events-export.status.json',self.export);self.assert_scope_refused()
        self.receipts();self.export['argv'][7]='2026-11-06 12:00:01+0000'
        self.write('events-export.status.json',self.export);self.assert_scope_refused()
        self.receipts();self.owned['udid']='22222222-2222-4222-8222-222222222222'
        self.write('owned-device.json',self.owned);self.assert_scope_refused()
        self.receipts();self.window['startUTC']='2026-11-06 11:59:59+0000'
        self.write('capture-window.json',self.window);self.assert_scope_refused()

    def test_malformed_impossible_or_noncanonical_dates_and_reversed_windows_refused(self):
        for stamp in ('not-a-date+0000','2026-02-30 12:01:00+0000','2026-11-06 24:00:00+0000',
                      '2026-11-6 12:01:00+0000','2026-11-06T12:01:00Z','2026-11-06 12:01:00+00:00',
                      '2026-11-06 12:01:00+0100','2026-11-06 11:59:59+0000'):
            self.receipts();self.export['argv'][9]=stamp
            self.write('events-export.status.json',self.export);self.assert_scope_refused()
        self.receipts();self.window['startUTC']='not-a-date+0000';self.export['argv'][7]=self.window['startUTC']
        self.write('capture-window.json',self.window);self.write('events-export.status.json',self.export);self.assert_scope_refused()

    def test_window_bound_exact_boundary_and_overlong(self):
        for stamp,ok in [('2026-11-06 12:45:00+0000',True),('2026-11-06 12:45:01+0000',False),
                         ('2026-11-07 12:01:00+0000',False)]:
            self.receipts();self.export['argv'][9]=stamp;self.write('events-export.status.json',self.export)
            self.assertEqual(capture_provenance(self.root)['exportCommandScopeVerified'],ok)

    def test_missing_oversized_duplicate_and_invalid_receipt_schemas_refused(self):
        for name in ('owned-device.json','capture-window.json'):
            for kind in ('missing','oversized','duplicate','extra','wrong-type'):
                self.receipts();path=self.root/name
                if kind=='missing':path.unlink()
                if kind=='oversized':path.write_bytes(b' '*65537)
                if kind=='duplicate':path.write_text('{"startUTC":"x","startUTC":"y"}')
                if kind=='extra':
                    value=json.loads(path.read_text());value['unexpected']='private payload';self.write(name,value)
                if kind=='wrong-type':path.write_text('[]')
                self.assert_scope_refused()
                proof=capture_provenance(self.root);self.assertIn(name,proof['missingOrInvalidReceipts'])
                self.assertNotIn('private payload',json.dumps(proof))
        for key,value in [('udid',None),('udid','not-a-uuid'),('udid','00000000-0000-0000-0000-000000000000'),
                          ('runtime','com.apple.CoreSimulator.SimRuntime.iOS-27-1'),('name',{})]:
            self.receipts();self.owned[key]=value;self.write('owned-device.json',self.owned);self.assert_scope_refused()

if __name__=='__main__':unittest.main()
