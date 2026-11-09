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
        self.assertEqual(set(value['entries']),{'xcode-version','sdk-settings',*self.paths,'simctl-executable','coresimulator-version'})
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
        for stage in ('parser','slice-hash','signature-regions'):
            with self.subTest(stage=stage):
                clock=[0];original_uuid=contract.arm64_uuid;original_hash=contract.hashlib.sha256
                at_final=[False]
                def regions(*args):
                    if at_final[0] and stage=='signature-regions':clock[0]=31
                    raise ValueError('synthetic_signature_absent')
                def uuid(path):
                    value=original_uuid(path)
                    if Path(path)==self.actual:
                        at_final[0]=True
                        if stage=='parser':clock[0]=31
                    return value
                calls=[0]
                def digest(raw):
                    calls[0]+=1
                    # Two metadata hashes + four thin tools twice + launcher + final twice.
                    if calls[0]==13 and stage=='slice-hash':clock[0]=31
                    return original_hash(raw)
                with patch.object(contract.time,'monotonic',side_effect=lambda:clock[0]),\
                        patch.object(contract,'arm64_uuid',side_effect=uuid),\
                        patch.object(contract.hashlib,'sha256',side_effect=digest),\
                        patch.object(contract,'signature_regions',side_effect=regions):value=self.inventory()
                self.assertFalse(value['complete'])
                self.assertIn('inventory_macho_changed_or_deadline',value['entries']['simctl-executable']['error'])
                self.assertNotIn('error',value['entries']['swift-frontend'])
    def test_final_macho_row_drift_is_mandatory_after_parser_and_slice_hash(self):
        for stage in ('parser','slice-hash','signature-regions'):
            with self.subTest(stage=stage):
                self.actual.write_bytes(thin());original_uuid=contract.arm64_uuid;original_hash=contract.hashlib.sha256
                at_final=[False]
                def regions(*args):
                    if at_final[0] and stage=='signature-regions':self.actual.write_bytes(thin()+b'drift')
                    raise ValueError('synthetic_signature_absent')
                def uuid(path):
                    value=original_uuid(path)
                    if Path(path)==self.actual:
                        at_final[0]=True
                        if stage=='parser':self.actual.write_bytes(thin()+b'drift')
                    return value
                calls=[0]
                def digest(raw):
                    calls[0]+=1
                    if calls[0]==13 and stage=='slice-hash':self.actual.write_bytes(thin()+b'drift')
                    return original_hash(raw)
                with patch.object(contract,'arm64_uuid',side_effect=uuid),\
                        patch.object(contract.hashlib,'sha256',side_effect=digest),\
                        patch.object(contract,'signature_regions',side_effect=regions):value=self.inventory()
                self.assertFalse(value['complete'])
                self.assertIn('inventory_macho_changed_or_deadline',value['entries']['simctl-executable']['error'])
                self.assertNotIn('error',value['entries']['swift-frontend'])
    def test_framework_metadata_only_for_exact_known_resolved_launcher_target(self):
        known='/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl'
        fake=self.root/'CoreSimulator.framework/Versions/A/Resources/bin/simctl'
        fake.parent.mkdir(parents=True);fake.write_bytes(thin())
        metadata=fake.parents[1]/'Info.plist'
        fields={'CFBundleIdentifier':'com.apple.CoreSimulator','CFBundleVersion':'1174.9.2','CFBundleShortVersionString':'1174.9.2'}
        metadata.write_bytes(plistlib.dumps(fields))
        self.paths['simctl'].write_text('#!/bin/bash\nexec "'+known+'" "${@}"\n')
        def path(value):return fake if str(value)==known else Path(value)
        with patch.object(contract,'Path',side_effect=path):value=self.inventory()
        self.assertEqual(value['entries']['coresimulator-version']['observed']['fields'],fields)
        self.assertEqual(value['entries']['coresimulator-version']['observed']['sha256'],sha(metadata))
        self.assertTrue(value['complete'])
    def test_other_launcher_target_never_reads_framework_metadata(self):
        value=self.inventory()
        self.assertEqual(value['entries']['coresimulator-version']['diagnostic'],'launcher_target_not_known_framework_path')
        self.assertEqual(value['entries']['coresimulator-version']['observed'],{})
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


def signed_macho(blob=None, trailing=b'trailer'):
    if blob is None:
        directory=struct.pack('>II',0xfade0c02,12)+b'code'
        blob=struct.pack('>III',0xfade0cc0,32,1)+struct.pack('>II',0,20)+directory
    header=struct.pack('<8I',0xfeedfacf,0x0100000c,0,2,2,40,0,0)
    return header+thin()[32:]+struct.pack('<4I',0x1d,16,80,len(blob))+b'EXECBYTE'+blob+trailing


class SignatureRegionTests(unittest.TestCase):
    def test_all_bytes_covered_and_code_directory_hash_bound(self):
        raw=signed_macho();value=contract.signature_regions(raw)
        self.assertEqual(value['signatureOffset'],80);self.assertEqual(value['signatureBytes'],32)
        self.assertEqual(value['coveredBytes'],len(raw));self.assertEqual(value['suffix']['bytes'],7)
        self.assertEqual(value['prefix']['sha256'],hashlib.sha256(raw[:80]).hexdigest())
        self.assertEqual(value['suffix']['sha256'],hashlib.sha256(b'trailer').hexdigest())
        self.assertEqual(value['nonSignatureSHA256'],hashlib.sha256(raw[:80]+raw[112:]).hexdigest())
        self.assertEqual(value['codeDirectories'][0]['sha256'],hashlib.sha256(raw[100:112]).hexdigest())
    def test_executable_mutation_changes_non_signature_hash(self):
        raw=signed_macho();changed=bytearray(raw);changed[72]^=1
        first=contract.signature_regions(raw);second=contract.signature_regions(changed)
        self.assertNotEqual(first['nonSignatureSHA256'],second['nonSignatureSHA256'])
        self.assertEqual(first['signatureSHA256'],second['signatureSHA256'])
    def test_signature_only_mutation_preserves_non_signature_hash(self):
        raw=signed_macho();changed=bytearray(raw);changed[108]^=1
        first=contract.signature_regions(raw);second=contract.signature_regions(changed)
        self.assertEqual(first['nonSignatureSHA256'],second['nonSignatureSHA256'])
        self.assertNotEqual(first['signatureSHA256'],second['signatureSHA256'])
        self.assertNotEqual(first['codeDirectories'],second['codeDirectories'])
    def test_trailing_file_bytes_are_not_excluded(self):
        first=contract.signature_regions(signed_macho())
        second=contract.signature_regions(signed_macho(trailing=b'Trailer'))
        self.assertNotEqual(first['suffix']['sha256'],second['suffix']['sha256'])
        self.assertNotEqual(first['nonSignatureSHA256'],second['nonSignatureSHA256'])
        self.assertEqual(first['signatureSHA256'],second['signatureSHA256'])
    def test_signature_padding_is_covered(self):
        blob=signed_macho()[80:112]+b'padding'
        first=contract.signature_regions(signed_macho(blob));second=contract.signature_regions(signed_macho(blob[:-1]+b'G'))
        self.assertEqual(first['superBlobTrailingBytes'],7)
        self.assertNotEqual(first['signatureSHA256'],second['signatureSHA256'])
        self.assertEqual(first['nonSignatureSHA256'],second['nonSignatureSHA256'])
    def test_absent_or_duplicate_signature_is_explicit(self):
        with self.assertRaisesRegex(ValueError,'signature_absent_or_duplicate'):contract.signature_regions(thin())
        raw=bytearray(signed_macho());struct.pack_into('<II',raw,16,3,56)
        raw[72:72]=struct.pack('<4I',0x1d,16,80,32)
        with self.assertRaisesRegex(ValueError,'signature_absent_or_duplicate'):contract.signature_regions(raw)
    def test_bad_signature_and_load_command_ranges_rejected(self):
        for index,value in ((64,4),(64,99999),(68,99999),(60,8),(20,32)):
            with self.subTest(index=index,value=value):
                raw=bytearray(signed_macho());struct.pack_into('<I',raw,index,value)
                with self.assertRaises(ValueError):contract.signature_regions(raw)
    def test_overlapping_or_out_of_range_superblob_entries_rejected(self):
        directory=struct.pack('>II',0xfade0c02,12)+b'code'
        overlap=struct.pack('>III',0xfade0cc0,40,2)+struct.pack('>4I',0,28,0x1000,28)+directory
        with self.assertRaisesRegex(ValueError,'signature_child_overlap'):contract.signature_regions(signed_macho(overlap))
        for slot,offset in ((0,4),(0,9999)):
            blob=struct.pack('>III',0xfade0cc0,32,1)+struct.pack('>II',slot,offset)+directory
            with self.assertRaisesRegex(ValueError,'signature_index_bounds'):contract.signature_regions(signed_macho(blob))
    def test_selected_slice_preserves_all_other_container_bytes(self):
        raw=b'CONTAINER'+signed_macho()+b'OTHER-SLICE'
        value=contract.signature_regions(raw,9,len(signed_macho()))
        self.assertEqual(value['signatureOffset'],89);self.assertEqual(value['coveredBytes'],len(raw))
        self.assertEqual(value['nonSignatureSHA256'],hashlib.sha256(raw[:89]+raw[121:]).hexdigest())


if __name__=='__main__':unittest.main()
