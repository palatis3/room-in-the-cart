"""One existing producer build; exact SDK/helper/settings prerequisites are retained."""
import os
from pathlib import Path
import shutil
from .contract import (ROOT, CONDITION, FLAG, read, frozen, tools, environment, source_snapshot,
                       selected_snapshot, products_snapshot, tool_inventory)
from .support import require, sha, atomic_json
from .runner import Runner


def project_args(tool, destination=None):
    args=['-project',str(ROOT/'ios/RoomInTheCart.xcodeproj'),'-configuration','Release',
          '-sdk',tool['SDKROOT'],'ARCHS=arm64','ONLY_ACTIVE_ARCH=YES',FLAG]
    if destination:args+=['-destination','platform=iOS Simulator,id='+destination]
    return args


def helper_source():
    helpers=[]
    for name in ('ios/App/RoomInTheCartApp.swift','ios/UITests/ReleasePerformanceUITests.swift'):
        text=(ROOT/name).read_text(); offset=text.rfind('\n'+CONDITION+'\n')
        require(offset>=0,'complete_helper_suffix:'+name);helpers.append(text[offset:])
    return 'import Foundation\nimport XCTest\n'+''.join(helpers)


def helper_typecheck(runner):
    path=runner.out/'CaptureHelpers.swift';path.write_text(helper_source())
    platform=Path(runner.tools['developer'])/'Platforms/iPhoneSimulator.platform/Developer'
    cache=runner.out.parent/'helper-module-cache';cache.mkdir(exist_ok=True)
    args=['-typecheck',str(path),'-swift-version','5','-sdk',runner.tools['SDKROOT'],
          '-target','arm64-apple-ios17.0-simulator','-F',str(platform/'Library/Frameworks'),
          '-D','RELEASE','-D','APP_SIGNPOST_CAPTURE_CONTROL','-module-cache-path',str(cache),'-I',str(platform/'usr/lib')]
    runner.command('helper-typecheck','swift-frontend',args,120)
    require((runner.out/'helper-typecheck-stdout.log').stat().st_size==0
            and (runner.out/'helper-typecheck-stderr.log').stat().st_size==0,'helper_diagnostics')
    return {'sha256':sha(path),'architecture':'arm64','SDKROOT':runner.tools['SDKROOT'],'argv':args}


def verify_settings(rows, target, sdk):
    matches=[r['buildSettings'] for r in rows if r.get('target')==target]
    require(len(matches)==1,'target_settings:'+target);v=matches[0]
    require(v['CONFIGURATION']=='Release' and Path(v['SDKROOT']).resolve()==Path(sdk)
            and v['ARCHS']=='arm64' and v['ONLY_ACTIVE_ARCH']=='YES' and v['SWIFT_VERSION']=='5.0'
            and v['IPHONEOS_DEPLOYMENT_TARGET']=='17.0','Release_arm64_settings:'+target)
    require({'RELEASE','APP_SIGNPOST_CAPTURE_CONTROL'}==set(v['SWIFT_ACTIVE_COMPILATION_CONDITIONS'].split())
            and 'DEBUG' not in v['SWIFT_ACTIVE_COMPILATION_CONDITIONS'].split(),'compile_gate:'+target)
    require(v['SWIFT_OPTIMIZATION_LEVEL']=='-O','optimized_settings:'+target)
    return {k:v[k] for k in ('CONFIGURATION','SDKROOT','ARCHS','ONLY_ACTIVE_ARCH','SWIFT_VERSION','IPHONEOS_DEPLOYMENT_TARGET','SWIFT_ACTIVE_COMPILATION_CONDITIONS','SWIFT_OPTIMIZATION_LEVEL')}


def verify_logging_template(raw):
    require(len(raw)<=1024**2, 'template_inventory_cap')
    entries=raw.decode('utf-8').splitlines()
    require(sum(line.strip()=='Logging' for line in entries)==1, 'exact_Logging_template_unavailable_or_ambiguous')
    return {'requiredTemplate':'Logging','matchingEntries':1,'status':'passed'}


def prepare(output, developer):
    output=Path(output);require(not output.exists(),'prepare_output_already_exists')
    runner=None;inventory=None;error=None;stage='source-contract'
    try:
        expected=frozen();stage='identity-inventory'
        inventory=tool_inventory(developer,expected)
        require(inventory['complete'],'identity_inventory_incomplete')
        stage='exact-tool-admission';accepted=tools(developer)
        stage='runner-setup';runner=Runner(output,accepted,360)
        atomic_json(output/'identity-inventory.json',inventory)
        runner.receipt['identityInventorySHA256']=sha(output/'identity-inventory.json')
        runner.save();stage='producer-prerequisites'
        from app_configuration import load_configuration
        load_configuration(ROOT,'Release')
        runner.receipt['sourceSnapshot']=source_snapshot()
        runner.receipt['environment']=environment(runner)
        templates=runner.command('templates','xctrace',['list','templates'],10,terminal_query=True)
        runner.receipt['templateInventory']={**verify_logging_template(templates.read_bytes()),
            'stdoutSHA256':sha(templates),'stderrSHA256':sha(runner.out/'templates-stderr.log'),
            'argv':[runner.tools['xctrace']['path'],'list','templates']}
        runner.save()
        runner.receipt['helper']=helper_typecheck(runner)
        settings={}
        for target in ('RoomInTheCart','RoomInTheCartUITests'):
            path=runner.command('settings-'+target,'xcodebuild',project_args(runner.tools)+['-target',target,'-showBuildSettings','-json'],60)
            settings[target]=verify_settings(read(path),target,runner.tools['SDKROOT'])
        runner.receipt['resolvedSettings']=settings
        require(selected_snapshot(ROOT,runner.receipt['sourceSnapshot']['files'])==runner.receipt['sourceSnapshot'],'sources_changed_during_prepare')
        runner.receipt['contractSHA256']=sha(Path(__file__).with_name('contract.json'))
    except BaseException as exc:error=type(exc).__name__+': '+str(exc)[:1024]
    finally:
        if runner is not None:runner.finish(error)
        else:
            # No command can have started before Runner returns. Retain diagnostics in
            # the existing always-uploaded prepare directory, including constructor failure.
            output.mkdir(parents=True,exist_ok=True)
            require(output.is_dir() and not output.is_symlink(),'prepare_failure_output')
            if inventory is not None:atomic_json(output/'identity-inventory.json',inventory)
            failure={'diagnosticOnly':True,'releaseAcceptance':False,'status':'failed','stage':stage,
                     'error':error,'processes':[],'nativeCommandsStarted':False,
                     'identityInventorySHA256':sha(output/'identity-inventory.json') if inventory is not None else None,
                     'rootAction':'Review the retained expected/observed tool identity. Accepted hashes are unchanged; no automatic admission or retry.'}
            atomic_json(output/'setup-failure.json',failure);atomic_json(output/'receipt.json',failure)
    require(error is None,error)


def build(prepared, output):
    require(not (ROOT/'.build/PerformanceBuild.log').exists(),'build_log_already_exists')
    preparation=read(prepared/'receipt.json');require(preparation['status']=='passed','producer_prepare_failed')
    require(selected_snapshot(ROOT,preparation['sourceSnapshot']['files'])==preparation['sourceSnapshot'],'source_before_build')
    runner=Runner(output,preparation['tools'],1500);error=None
    try:
        args=project_args(runner.tools,preparation['environment']['device'])+['-scheme','RoomInTheCart-Performance',
              '-parallel-testing-enabled','NO','-jobs','2','-derivedDataPath',str(ROOT/'.build/DerivedData'),
              '-enableCodeCoverage','NO','-enableAddressSanitizer','NO','-enableThreadSanitizer','NO',
              '-enableUndefinedBehaviorSanitizer','NO','CODE_SIGN_IDENTITY=-','build-for-testing']
        runner.command('build','xcodebuild',args,1440)
        require(selected_snapshot(ROOT,preparation['sourceSnapshot']['files'])==preparation['sourceSnapshot'],'source_after_build')
        runner.receipt['prepareReceiptSHA256']=sha(prepared/'receipt.json')
    except BaseException as exc:error=type(exc).__name__+': '+str(exc)
    finally:
        runner.finish(error)
        # Original build-log name retained, combining both separately retained streams.
        with (ROOT/'.build/PerformanceBuild.log').open('xb') as log:
            for name in ('build-stdout.log','build-stderr.log'):
                if (output/name).exists():
                    with (output/name).open('rb') as source:shutil.copyfileobj(source,log)
    require(error is None,error)


def package(prepared, build_output, products):
    from performance_plan_provenance import context
    require(not (products/'app-observation-producer.json').exists(),'producer_supplement_already_exists')
    p=read(prepared/'receipt.json');b=read(build_output/'receipt.json')
    require(p['status']==b['status']=='passed' and b['prepareReceiptSHA256']==sha(prepared/'receipt.json'),'build_prerequisites')
    require(read(ROOT/'.build/performance-plan-producer.json')['status']=='passed','original_product_provenance')
    require(selected_snapshot(ROOT,p['sourceSnapshot']['files'])==p['sourceSnapshot'],'packaged_source')
    result={'schema':1,'diagnosticOnly':True,'releaseAcceptance':False,'profile':'app-scroll-observation',
            'context':context('producer',ROOT),'sourceSnapshot':p['sourceSnapshot'],'productsSnapshot':products_snapshot(products),
            'preparation':p,'build':b,'contractSHA256':sha(Path(__file__).with_name('contract.json')),
            'originalProvenanceSHA256':sha(ROOT/'.build/performance-plan-producer.json')}
    atomic_json(products/'app-observation-producer.json',result)
