"""Consumer configuration, sealed custody, and cleanup gate for one owned attempt."""
import os
from pathlib import Path
import time
from .contract import (ROOT, read, frozen, tools, environment, selected_snapshot, products_snapshot,
                       snapshot, verify_config, copy_snapshot)
from .support import require, sha, manifest, modes, atomic_json, arm64_uuid
from .runner import Runner
from .schema import validate_receipt


def configure(evidence, products):
    from performance_plan_provenance import context
    frozen();product=read(products/'app-observation-producer.json');current=context('consumer',ROOT)
    previous=product['context']
    for key in ('repository','runID','sourceSHA'):
        require(previous[key]==current[key],'producer_context:'+key)
    require(int(previous['attempt'])<=int(current['attempt']),'producer_attempt')
    require(product['diagnosticOnly'] is True and product['releaseAcceptance'] is False
            and product['profile']=='app-scroll-observation','producer_profile')
    require(product['contractSHA256']==sha(Path(__file__).with_name('contract.json')),'producer_contract')
    require(selected_snapshot(ROOT,product['sourceSnapshot']['files'])==product['sourceSnapshot'],'consumer_source')
    require(products_snapshot(products)==product['productsSnapshot'],'consumer_products')
    require(sha(products/'performance-plan-producer.json')==product['originalProvenanceSHA256'],'original_producer_binding')
    inputs={}
    for name in ('plan-provenance.json','plan-provenance-after-setup.json','setup.json','test-simulator-ownership.json','native-attempt.json'):
        inputs[name]=sha(evidence/name)
    for name in ('plan-provenance.json','plan-provenance-after-setup.json'):
        require(read(evidence/name)['status']=='passed','ordinary_provenance_failed')
    runner=Runner(evidence/'observation-preflight',tools(os.environ['DEVELOPER_DIR']),120);error=None
    try:
        env=environment(runner);t=runner.tools
        plans=list(products.glob('RoomInTheCart-Performance_iphonesimulator*.xctestrun'));require(len(plans)==1,'exact_original_plan')
        c={'diagnosticOnly':True,'releaseAcceptance':False,'simulatorUDID':env['device'],'environment':env,
           'sourceRoot':str(ROOT),'sourceSnapshot':product['sourceSnapshot'],'productsRoot':str(products),
           'productsSnapshot':snapshot(products,512*1024**2,8192),'plan':str(plans[0]),'planSHA256':sha(plans[0]),
           'setupReceipt':str(evidence/'setup.json'),'setupReceiptSHA256':inputs['setup.json'],
           'evidenceRoot':str(evidence),'inputReceipts':inputs,'tools':t,
           'producerSHA256':sha(products/'app-observation-producer.json'),
           'launcherArguments':{'launcher':t['simctl']['path'],'launcher_sha':t['simctl']['sha256'],
                                'executable':t['simctl']['executable'],'executable_sha':t['simctl']['executableSHA256']}}
        from performance_plan_provenance import settings
        c['nativeInvocationSettings']=settings(os.environ)
        require(c['nativeInvocationSettings']==read(evidence/'plan-provenance-after-setup.json')['observations']['invoking']['settings'],'native_invoking_settings_changed')
        import hashlib
        c['nativeLibraryEnvironmentSHA256']=hashlib.sha256(os.environ['DYLD_INSERT_LIBRARIES'].encode()).hexdigest() if 'DYLD_INSERT_LIBRARIES' in os.environ else None
        verify_config(c);atomic_json(evidence/'observation-config.json',c)
    except BaseException as exc:error=type(exc).__name__+': '+str(exc)
    finally:runner.finish(error)
    require(error is None,error)


def seal(evidence):
    """Before cleanup: preserve complete source/products and installed bytes/mode attestations."""
    capture=evidence/'observation-capture';receipt=read(capture/'receipt.json');c=receipt['config']
    output=evidence/'observation-custody';output.mkdir(exist_ok=False);started=time.monotonic()
    proof={'diagnosticOnly':True,'releaseAcceptance':False,'sealed':False,'collectionQualified':False,
           'captureReceiptSHA256':sha(capture/'receipt.json'),'configSHA256':sha(evidence/'observation-config.json')}
    def budget():
        require(time.monotonic()-started<=120,'seal_wall_cap')
        entries=list(output.rglob('*'));require(len(entries)<=16384,'seal_file_cap')
        require(sum(p.stat().st_size for p in entries if p.is_file())<=768*1024**2,'seal_byte_cap')
    try:
        verify_config(c)
        require(receipt['allKnownOwnedProcessesTerminal'] is True,'known_processes_not_terminal')
        require(set(receipt['bindings'])=={'app','runner'},'unbound_target_cleanup_blocked')
        from .owned import Identity
        identity=Identity()
        installed={}
        for role,item in receipt['bindings'].items():
            value=item['binding'];observed=identity.read(value['pid'])
            require(observed is None or observed['startTimeMicros']!=value['startTimeMicros'],'owned_process_still_live')
            exe=Path(value['executable']);bundle=Path(c['productsRoot'])/'Release-iphonesimulator'/exe.parent.name
            require(sha(exe)==item['executableSHA256'] and arm64_uuid(exe)==item['arm64UUID'],'installed_executable')
            require(manifest(exe.parent)==item['installedBundleManifest']==manifest(bundle),'installed_bundle_bytes')
            require(modes(exe.parent)==item['installedModes'],'installed_modes_changed')
            installed[role]={'observedInstalledPath':str(exe.parent),'productRelativePath':str(bundle.relative_to(Path(c['productsRoot']))),
                             'files':item['installedBundleManifest'],'modes':item['installedModes'],
                             'binding':value,'executableSHA256':item['executableSHA256'],'arm64UUID':item['arm64UUID']}
        copy_snapshot(ROOT,output/'source',c['sourceSnapshot'],budget)
        copy_snapshot(c['productsRoot'],output/'products',c['productsSnapshot'],budget,cap=512*1024**2)
        proof.update(installed=installed,sourceSnapshot=c['sourceSnapshot'],productsSnapshot=c['productsSnapshot'],
                     sourceManifestSHA256=sha(evidence/'observation-config.json'),portableScope='Installed bytes/modes observed before deletion; product bytes and sources retained. No claim of later live installation.')
        for name in ('setup.json','plan-provenance.json','plan-provenance-after-setup.json','test-simulator-ownership.json','native-attempt.json'):
            require(sha(evidence/name)==c['inputReceipts'][name],'input_custody:'+name)
        try:
            validate_receipt(receipt,c['simulatorUDID']);proof['collectionQualified']=True
        except (ValueError,KeyError,TypeError) as exc:proof['collectionError']=str(exc)
        # Source/products are immutable copies; trace/result bytes and modes must remain exact.
        for name,key,cap in [('app.trace','originalTrace',128*1024**2),('Performance.xcresult','originalResult',512*1024**2)]:
            if key in receipt:require(snapshot(capture/name,cap)==receipt[key],'original_evidence_changed:'+name)
        proof['captureSnapshot']=snapshot(capture,768*1024**2,8192)
        proof['sealed']=True;budget()
    except BaseException as exc:proof['error']=type(exc).__name__+': '+str(exc)
    finally:atomic_json(output/'seal.json',proof)
    require(proof['sealed'],proof.get('error','seal_failed'))
    return proof


def verify_seal(evidence, require_collection=False):
    output=evidence/'observation-custody';proof=read(output/'seal.json');require(proof['sealed'] is True,'custody_not_sealed')
    require(sha(evidence/'observation-config.json')==proof['configSHA256'],'config_custody')
    receipt=read(evidence/'observation-capture/receipt.json');c=receipt['config']
    require(sha(evidence/'observation-capture/receipt.json')==proof['captureReceiptSHA256'],'capture_receipt_custody')
    require(snapshot(evidence/'observation-capture',768*1024**2,8192)==proof['captureSnapshot'],'capture_custody')
    for role,cap in [('source',128*1024**2),('products',512*1024**2)]:
        require(snapshot(output/role,cap,16384)==proof[role+'Snapshot'],'portable_'+role+'_custody')
    for name,digest in c['inputReceipts'].items():require(sha(evidence/name)==digest,'sealed_input_receipt_changed:'+name)
    for role,item in proof['installed'].items():
        bundle=output/'products'/item['productRelativePath']
        require(manifest(bundle)==item['files']==receipt['bindings'][role]['installedBundleManifest'],'portable_installed_product_bytes')
        require(item['modes']==receipt['bindings'][role]['installedModes'],'installed_mode_attestation')
    if require_collection:
        require(proof['collectionQualified'] is True,'collection_unqualified')
        validate_receipt(receipt,c['simulatorUDID'])
    return proof


def cleanup_gate(evidence):
    if not (evidence/'native-attempt.json').exists():return
    proof=verify_seal(evidence)
    # Failed collections may leave unbound XCTest diagnostic descendants. No automatic device cleanup then.
    require(proof['collectionQualified'] is True,'failed_collection_requires_root_descendant_audit_before_cleanup')
