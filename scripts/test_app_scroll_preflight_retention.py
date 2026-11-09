"""File-only synthetic tool identity and rejected-preflight retention controls."""
import copy
import hashlib
import inspect
import json
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
from unittest.mock import patch
from app_scroll_observation import contract, producer
from app_scroll_observation.support import sha


def thin():
    return struct.pack('<8I',0xfeedfacf,0x0100000c,0,2,1,24,0,0)+struct.pack('<II',0x1b,24)+bytes(range(16))


class PreflightRetentionTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name).resolve();self.developer=self.root/'Xcode.app/Contents/Developer'
        self.version=self.developer.parent/'version.plist';self.version.parent.mkdir(parents=True)
        self.version.write_bytes(plistlib.dumps({'CFBundleShortVersionString':'27.1','ProductBuildVersion':'27A9275'}))
        self.sdk=self.developer/'Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk'
        self.sdk.mkdir(parents=True);(self.sdk/'SDKSettings.plist').write_bytes(plistlib.dumps({'Version':'27.1','CanonicalName':'iphonesimulator27.1'}))
        self.paths={}
        for name,relative in {'xcodebuild':'usr/bin/xcodebuild','xctrace':'usr/bin/xctrace','simctl':'usr/bin/simctl',
                             'xcresulttool':'usr/bin/xcresulttool','swift-frontend':'Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend'}.items():
            p=self.developer/relative;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(thin());self.paths[name]=p
        self.actual=self.root/'actual-simctl';self.actual.write_bytes(thin())
        self.paths['simctl'].write_text('#!/bin/bash\nexec "'+str(self.actual)+'" "${@}"\n')
        self.expected={'qualifiedToolHashes':{n:sha(p) for n,p in self.paths.items() if n!='simctl'},
                       'qualifiedSDKSettingsSHA256':sha(self.sdk/'SDKSettings.plist')}
    def inventory(self):return contract.tool_inventory(self.developer,self.expected)
    def prepare_failure(self,reason):
        output=self.root/'prepare'
        with patch.object(contract,'frozen',return_value=self.expected),patch.object(producer,'frozen',return_value=self.expected),\
                patch.object(producer,'Runner') as runner,patch.object(producer,'helper_typecheck') as helper,\
                patch.object(contract.subprocess,'run',side_effect=AssertionError('No commands permitted')),\
                self.assertRaisesRegex(ValueError,reason):
            producer.prepare(output,self.developer)
        runner.assert_not_called();helper.assert_not_called()
        receipt=json.loads((output/'receipt.json').read_text());inventory=json.loads((output/'identity-inventory.json').read_text())
        self.assertEqual(receipt['status'],'failed');self.assertFalse(receipt['nativeCommandsStarted'])
        self.assertEqual(receipt['identityInventorySHA256'],sha(output/'identity-inventory.json'))
        self.assertEqual(receipt,json.loads((output/'setup-failure.json').read_text()))
        self.assertLess((output/'identity-inventory.json').stat().st_size,64*1024)
        return receipt,inventory
    def test_rejected_xcodebuild_retains_all_tools_sdk_and_version_without_runner(self):
        self.expected['qualifiedToolHashes']['xcodebuild']='f'*64
        before=copy.deepcopy(self.expected);receipt,value=self.prepare_failure('qualified_tool_changed:xcodebuild')
        self.assertEqual(receipt['stage'],'exact-tool-admission');self.assertEqual(self.expected,before)
        self.assertEqual(set(value['entries']),{'xcode-version','sdk-settings',*self.paths,'simctl-executable'})
        row=value['entries']['xcodebuild'];self.assertFalse(row['matchesExpectedSHA256'])
        self.assertEqual(row['expectedSHA256'],'f'*64);self.assertEqual(row['observed']['sha256'],sha(self.paths['xcodebuild']))
        self.assertEqual(row['observed']['bytes'],len(thin()));self.assertEqual(row['observed']['magic'],'cffaedfe')
        self.assertEqual(row['observed']['arm64UUID'],'00010203-0405-0607-0809-0A0B0C0D0E0F')
        self.assertEqual(row['observed']['arm64SliceSHA256'],sha(self.paths['xcodebuild']))
        self.assertEqual(value['entries']['xcode-version']['observed']['fields']['ProductBuildVersion'],'27A9275')
    def test_sdk_mismatch_still_collects_later_tool_identities(self):
        self.expected['qualifiedSDKSettingsSHA256']='e'*64
        _,value=self.prepare_failure('qualified_SDK_metadata_changed')
        self.assertFalse(value['entries']['sdk-settings']['matchesExpectedSHA256'])
        self.assertIn('sha256',value['entries']['swift-frontend']['observed'])
    def test_version_mismatch_still_collects_tools_before_original_guard_rejects(self):
        self.version.write_bytes(plistlib.dumps({'CFBundleShortVersionString':'27.2','ProductBuildVersion':'other'}))
        _,value=self.prepare_failure('exact_Xcode')
        self.assertFalse(value['entries']['xcode-version']['matchesExpectedFields'])
        self.assertIn('sha256',value['entries']['xctrace']['observed'])
    def test_missing_tool_is_explicit_and_does_not_hide_other_rows(self):
        self.paths['xcodebuild'].unlink()
        receipt,value=self.prepare_failure('identity_inventory_incomplete')
        self.assertEqual(receipt['stage'],'identity-inventory');self.assertFalse(value['complete'])
        self.assertIn('error',value['entries']['xcodebuild']);self.assertIn('sha256',value['entries']['xcresulttool']['observed'])
    def test_missing_version_metadata_still_retains_setup_failure_and_tools(self):
        self.version.unlink()
        receipt,value=self.prepare_failure('identity_inventory_incomplete')
        self.assertEqual(receipt['stage'],'identity-inventory')
        self.assertIn('error',value['entries']['xcode-version'])
        self.assertIn('sha256',value['entries']['swift-frontend']['observed'])
    def test_malformed_sdk_metadata_still_retains_setup_failure_and_tools(self):
        (self.sdk/'SDKSettings.plist').write_bytes(b'<?xml version="1.0"?><plist><dict>')
        receipt,value=self.prepare_failure('identity_inventory_incomplete')
        self.assertEqual(receipt['stage'],'identity-inventory')
        self.assertIn('error',value['entries']['sdk-settings'])
        self.assertIn('sha256',value['entries']['xctrace']['observed'])
    def test_universal_reports_slice_hash_without_accepting_whole_file_difference(self):
        raw=thin();offset=64
        fat=struct.pack('>II',0xcafebabe,1)+struct.pack('>IIIII',0x0100000c,0,offset,len(raw),0)
        self.paths['xcodebuild'].write_bytes(fat+b'\0'*(offset-len(fat))+raw)
        _,value=self.prepare_failure('qualified_tool_changed:xcodebuild')
        observed=value['entries']['xcodebuild']['observed']
        self.assertEqual(observed['container'],'universal')
        self.assertEqual(observed['arm64SliceSHA256'],hashlib.sha256(raw).hexdigest())
        self.assertNotEqual(observed['sha256'],observed['arm64SliceSHA256'])
    def test_bad_macho_parse_is_diagnostic_and_never_waives_hash_guard(self):
        self.paths['xcodebuild'].write_bytes(b'\xcf\xfa\xed\xfeinvalid')
        _,value=self.prepare_failure('qualified_tool_changed:xcodebuild')
        self.assertIn('machODiagnosticError',value['entries']['xcodebuild']);self.assertTrue(value['complete'])
    def test_oversize_file_is_not_read_and_remaining_rows_are_retained(self):
        with self.paths['xcodebuild'].open('wb') as stream:stream.truncate(512*1024**2+1)
        receipt,value=self.prepare_failure('identity_inventory_incomplete')
        self.assertIn('inventory_byte_cap',value['entries']['xcodebuild']['error'])
        self.assertNotIn('sha256',value['entries']['xcodebuild']['observed'])
        self.assertIn('sha256',value['entries']['xctrace']['observed'])
    def test_deadline_produces_explicit_unobserved_rows(self):
        with patch.object(contract.time,'monotonic',side_effect=[0]+[31]*100):value=self.inventory()
        self.assertFalse(value['complete']);self.assertIn('inventory_deadline',value['entries']['xcodebuild']['error'])
    def test_final_macho_row_deadline_is_mandatory_after_parser_and_slice_hash(self):
        for stage in ('parser','slice-hash'):
            with self.subTest(stage=stage):
                clock=[0];original_uuid=contract.arm64_uuid;original_hash=contract.hashlib.sha256
                def uuid(path):
                    value=original_uuid(path)
                    if Path(path)==self.actual and stage=='parser':clock[0]=31
                    return value
                calls=[0]
                def digest(raw):
                    calls[0]+=1
                    # Two metadata hashes + four thin tools twice + launcher + final twice.
                    if calls[0]==13 and stage=='slice-hash':clock[0]=31
                    return original_hash(raw)
                with patch.object(contract.time,'monotonic',side_effect=lambda:clock[0]),\
                        patch.object(contract,'arm64_uuid',side_effect=uuid),\
                        patch.object(contract.hashlib,'sha256',side_effect=digest):value=self.inventory()
                self.assertFalse(value['complete'])
                self.assertIn('inventory_macho_changed_or_deadline',value['entries']['simctl-executable']['error'])
                self.assertNotIn('error',value['entries']['swift-frontend'])
    def test_final_macho_row_drift_is_mandatory_after_parser_and_slice_hash(self):
        for stage in ('parser','slice-hash'):
            with self.subTest(stage=stage):
                self.actual.write_bytes(thin());original_uuid=contract.arm64_uuid;original_hash=contract.hashlib.sha256
                def uuid(path):
                    value=original_uuid(path)
                    if Path(path)==self.actual and stage=='parser':self.actual.write_bytes(thin()+b'drift')
                    return value
                calls=[0]
                def digest(raw):
                    calls[0]+=1
                    if calls[0]==13 and stage=='slice-hash':self.actual.write_bytes(thin()+b'drift')
                    return original_hash(raw)
                with patch.object(contract,'arm64_uuid',side_effect=uuid),\
                        patch.object(contract.hashlib,'sha256',side_effect=digest):value=self.inventory()
                self.assertFalse(value['complete'])
                self.assertIn('inventory_macho_changed_or_deadline',value['entries']['simctl-executable']['error'])
                self.assertNotIn('error',value['entries']['swift-frontend'])
    def test_existing_output_is_not_overwritten(self):
        out=self.root/'prepare';out.mkdir();(out/'receipt.json').write_text('first failure')
        with patch.object(producer,'tool_inventory') as inventory,self.assertRaisesRegex(ValueError,'prepare_output_already_exists'):
            producer.prepare(out,self.developer)
        inventory.assert_not_called();self.assertEqual((out/'receipt.json').read_text(),'first failure')
    def test_constructor_rejection_retains_inventory_in_created_directory(self):
        output=self.root/'prepare'
        def reject(*args):output.mkdir();raise ValueError('constructor_tool_drift')
        with patch.object(producer,'frozen',return_value=self.expected),patch.object(contract,'frozen',return_value=self.expected),\
                patch.object(producer,'Runner',side_effect=reject),self.assertRaisesRegex(ValueError,'constructor_tool_drift'):
            producer.prepare(output,self.developer)
        receipt=json.loads((output/'receipt.json').read_text());self.assertEqual(receipt['stage'],'runner-setup')
        self.assertTrue((output/'identity-inventory.json').is_file());self.assertFalse(receipt['nativeCommandsStarted'])
    def test_existing_workflow_always_uploads_prepare_directory(self):
        text=(contract.ROOT/'.github/workflows/ios-performance.yml').read_text()
        block=text.split('      - name: Retain Release build log\n',1)[1].split('  performance-tests:',1)[0]
        self.assertIn('if: always()',block);self.assertIn('.build/app-observation-producer/prepare/',block)
    def test_no_native_inventory_commands_added(self):
        source=inspect.getsource(contract.tool_inventory)
        self.assertNotIn('subprocess',source);self.assertNotIn('Runner(',source)
        self.assertNotIn('Popen',source)


if __name__=='__main__':unittest.main()
