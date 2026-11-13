#!/usr/bin/env python3
"""Offline exported-attachment inventory/measurement summary; never opens xcresult."""
import argparse, hashlib, json, math, re, struct
from pathlib import Path

SIZES = {'small': 'S', 'large': 'L', 'ax5': 'AccessibilityXXXL'}
TARGETS = {
    'after': ('$40.69', 'Expected total, $40.69', 'household.decision.after-total'),
    'over': ('$2.69', 'Over cap, $2.69', 'household.decision.over-cap'),
    'before': ('$37.20', 'Before this decision, $37.20', 'household.decision.before-total'),
    'change': ('$3.49', 'Cost change, $3.49', ''),
    'cap': ('$38.00', 'Cap, $38.00', ''),
    'review-decision': ('Review decision', 'Review decision', 'household.decision.review'),
    'review-heading': ('Review before applying', 'Review before applying', ''),
}
KINDS = {'crop', 'screen', 'ancestry', 'metrics'}
NAME = re.compile(r'^S24-measure-(small|large|ax5)-(after|over|before|change|cap|review-decision|review-heading)-(crop|screen|ancestry|metrics(?:\.json)?)(?:_\d+_[0-9A-Fa-f-]{36})?\.(png|txt|json)$')
CANCEL = re.compile(r'^S24-measure-(small|large|ax5)-cancel-zero-writes(?:_\d+_[0-9A-Fa-f-]{36})?\.png$')
METHOD = 'HouseholdRequestPackUITests/testMeasureRequestDecisionMoneyAndReviewLabels'
FONTS = {'body', 'body-size-monospaced-digits', 'caption1', 'headline'}
LIMIT = 'Complete attachment inventory only. No test, font-scaling, contrast, accessibility-audit or physical acceptance pass is inferred. Ink masks may include decoration or miss pale glyphs; review crops. Bitmap row order is retained.'

def require(condition, message):
    if not condition: raise ValueError(message)

def number(value, label, minimum=None):
    require(type(value) in (int, float) and math.isfinite(value), 'Non-finite/non-number: '+label)
    if minimum is not None: require(value >= minimum, 'Out of range: '+label)
    return value

def rect(value, label):
    require(isinstance(value, dict) and set(value)=={'x','y','width','height'}, 'Bad rectangle: '+label)
    for k,v in value.items(): number(v,label+'.'+k,0 if k in ('width','height') else None)
    return value

def load_json(data):
    def pairs(items):
        result={}
        for k,v in items:
            require(k not in result,'Duplicate JSON key: '+k);result[k]=v
        return result
    return json.loads(data, object_pairs_hook=pairs, parse_constant=lambda value: (_ for _ in ()).throw(ValueError('Invalid JSON constant '+value)))

def checked_file(root, name, cap):
    require(isinstance(name,str) and name and Path(name).name==name and name not in ('.','..'), 'Unsafe exported filename')
    p=root/name
    require(not p.is_symlink() and p.is_file(), 'Missing/nonregular attachment: '+name)
    require(p.stat().st_size<=cap,'Attachment exceeds byte cap: '+name)
    data=p.read_bytes()
    return p,data,{'path':str(p),'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()}

def png_dimensions(data):
    require(len(data)>=24 and data[:8]==b'\x89PNG\r\n\x1a\n' and data[12:16]==b'IHDR','Invalid PNG header')
    w,h=struct.unpack('>II',data[16:24]);require(0<w<=8192 and 0<h<=8192,'Unbounded PNG dimensions');return w,h

def identify(name):
    match=NAME.fullmatch(name)
    if not match: return None
    size,key,kind,ext=match.groups();kind='metrics' if kind.startswith('metrics') else kind
    require(ext=='png' if kind in ('crop','screen') else ext in ('txt','json'),'Wrong attachment extension')
    return size,key,kind

def inspect_export(directory):
    root=Path(directory).absolute()
    require(root.is_dir() and not root.is_symlink(),'Input must be an exported-attachment directory')
    require(all(not p.endswith('.xcresult') for p in root.parts),'xcresult input forbidden')
    require(root.resolve()==root,'Symlink-containing input path forbidden')
    _,manifest_bytes,manifest_file=checked_file(root,'manifest.json',2_000_000)
    manifest=load_json(manifest_bytes);require(isinstance(manifest,list) and len(manifest)<=100,'Bad/oversized export manifest')
    groups={};used=set();identities=set();count=0
    for test in manifest:
        require(isinstance(test,dict) and isinstance(test.get('attachments'),list),'Malformed test export')
        for attachment in test['attachments']:
            count+=1;require(count<=1000,'Too many manifest attachments')
            name=attachment.get('suggestedHumanReadableName','');identity=identify(name)
            if identity is None:
                require(not name.startswith('S24-measure-') or CANCEL.fullmatch(name),'Unrecognized measurement attachment: '+name)
                continue
            size,key,kind=identity
            suffix={'small':'Small','large':'Large','ax5':'AX5'}[size]
            expected=METHOD+suffix
            require(test.get('testIdentifier') in (expected+'()',expected,'RoomInTheCartUITests/'+expected+'()','RoomInTheCartUITests/'+expected),'Wrong test identity for '+name)
            require(identity not in groups,'Duplicate measurement identity: '+str(identity))
            filename=attachment.get('exportedFileName');require(filename not in used,'Exported file reused across groups');used.add(filename)
            path,data,file_info=checked_file(root,filename,16_000_000 if kind in ('crop','screen') else 2_000_000)
            if kind in ('crop','screen'): file_info['dimensionsPixels']=list(png_dimensions(data))
            device=(attachment.get('deviceId'),attachment.get('deviceName'),attachment.get('configurationName'))
            require(all(isinstance(v,str) and v for v in device),'Missing device/configuration identity')
            identities.add(device);number(attachment.get('timestamp'),'attachment timestamp',0)
            file_info['attachmentName']=name;file_info['timestamp']=attachment['timestamp']
            groups[identity]=(data,file_info)
    expected={(size,key,kind) for size in SIZES for key in TARGETS for kind in KINDS}
    require(set(groups)==expected,'Missing/unexpected measurement identities: '+str(sorted(expected-set(groups))))
    require(len(identities)==1,'Mixed device/configuration identities')
    rows=[]
    for size in SIZES:
        for key,(label,owner,identifier) in TARGETS.items():
            files={kind:groups[size,key,kind][1] for kind in sorted(KINDS)}
            m=load_json(groups[size,key,'metrics'][0]);require(isinstance(m,dict) and m.get('schema')==1,'Unsupported metrics schema')
            for field,value in [('size',size),('key',key),('label',label),('ownerLabel',owner),('ownerIdentifier',identifier)]:
                require(m.get(field)==value,'Mismatched metadata '+field+' for '+size+'/'+key)
            category='UICTContentSizeCategory'+SIZES[size]
            require(m.get('requestedCategory')==category and m.get('launchArgument')==category,'Wrong requested content size')
            require(m.get('hittable') is True,'Measurement target not hittable')
            require(type(m.get('enabled')) is bool,'Missing enabled state')
            for field in ('ownerFrame','targetFrame','readingViewport','dragArea'): rect(m.get(field),field)
            target=m['targetFrame'];require(target['width']>0 and target['height']>0,'Empty target frame')
            vp=m['readingViewport']
            for field in ('ownerFrame','targetFrame'):
                r=m[field];require(r['x']>=vp['x'] and r['y']>=vp['y'] and r['x']+r['width']<=vp['x']+vp['width']+1e-6 and r['y']+r['height']<=vp['y']+vp['height']+1e-6,'Clipped '+field)
            w,h=files['crop']['dimensionsPixels'];require([m.get('cropWidthPixels'),m.get('cropHeightPixels')]==[w,h],'Crop metadata/image dimension mismatch')
            sx=number(m.get('pixelsPerPointX'),'pixelsPerPointX',1e-9);sy=number(m.get('pixelsPerPointY'),'pixelsPerPointY',1e-9)
            require(math.isclose(sx,w/target['width'],rel_tol=1e-8) and math.isclose(sy,h/target['height'],rel_tol=1e-8),'Invalid pixel/point normalization')
            fonts=m.get('referenceFonts');require(isinstance(fonts,list) and len(fonts)==4 and {f.get('reference') for f in fonts}==FONTS,'Missing/duplicate reference fonts')
            for f in fonts:
                require(isinstance(f.get('fontName'),str),'Missing reference font name')
                for field in ('pointSize','lineHeight','capHeight','xHeight','ascender','descender'): number(f.get(field),'font '+field)
                rect(f.get('textBounds'),'font textBounds')
            pixels=m.get('pixels');require(isinstance(pixels,dict),'Missing pixel metrics')
            require(pixels.get('colorSpace')=='sRGB' and pixels.get('layout')=='32-bit big-endian RGBX','Wrong pixel interpretation')
            low=number(pixels.get('cropLuminanceP01'),'luminance low',0);high=number(pixels.get('cropLuminanceP99'),'luminance high',0)
            require(low<=high<=1,'Invalid luminance range')
            contrast=number(pixels.get('percentileContrastEstimate'),'contrast',1)
            require(math.isclose(contrast,(high+.05)/(low+.05),rel_tol=1e-8),'Inconsistent contrast estimate')
            masks=pixels.get('inkCandidates');require(isinstance(masks,list) and len(masks)==2 and {x.get('absoluteLinearLuminanceDelta') for x in masks}=={.1,.2},'Missing/duplicate threshold masks')
            normalized=[]
            for mask in masks:
                n=mask.get('pixelCount');require(type(n) is int and 0<=n<=w*h,'Invalid ink pixel count')
                require(type(mask.get('touchesCropEdge')) is bool,'Missing ink edge state')
                bounds=mask.get('boundsInBitmapPixels');points=None
                if n==0: require(bounds is None,'Empty mask must have null bounds')
                else:
                    rect(bounds,'ink bounds');require(bounds['x']>=0 and bounds['y']>=0 and bounds['width']>0 and bounds['height']>0 and bounds['x']+bounds['width']<=w and bounds['y']+bounds['height']<=h,'Ink bounds outside crop')
                    require(n<=bounds['width']*bounds['height'],'Ink count exceeds bounds')
                    points={k:v/(sx if k in ('x','width') else sy) for k,v in bounds.items()}
                normalized.append({**mask,'boundsInPointsBitmapOrder':points})
            ancestry=groups[size,key,'ancestry'][0].decode('utf8')
            require(ancestry.startswith('OWNER\n') and '\nTARGET\n' in ancestry,'Invalid ancestry attachment')
            rows.append({'size':size,'key':key,'label':label,'ownerLabel':owner,'ownerIdentifier':identifier,'requestedCategory':category,'targetFrame':target,'ownerFrame':m['ownerFrame'],'cropScope':m.get('cropScope'),'cropDimensionsPixels':[w,h],'pixelsPerPoint':[sx,sy],'imageScale':m.get('imageScale'),'inkCandidates':normalized,'percentileContrastEstimate':contrast,'backgroundLuminance':pixels.get('backgroundLuminance'),'referenceFonts':fonts,'referenceScope':m.get('referenceScope'),'appTraitsObservation':m.get('appTraitsObservation'),'osVersion':m.get('osVersion'),'files':files})
    return {'status':'complete-export-inventory','acceptance':'not assessed','limits':LIMIT,'manifest':manifest_file,'deviceConfiguration':list(next(iter(identities))),'expectedGroups':21,'observedGroups':len(rows),'expectedAttachments':84,'observedAttachments':len(groups),'imageFiles':{row['size']+'/'+row['key']:{kind:row['files'][kind] for kind in ('crop','screen')} for row in rows},'measurements':rows}

def table(summary):
    lines=['# Raw S24 measurement summary','',LIMIT,'','| Size | Target | Ink 0.10 (pt w×h) | Ink 0.20 (pt w×h) | Contrast estimate | Body / mono reference pt | Crop |','|---|---|---|---|---|---|---|']
    for row in summary['measurements']:
        masks={m['absoluteLinearLuminanceDelta']:m for m in row['inkCandidates']};dimensions=[]
        for threshold in (.1,.2):
            m=masks[threshold];r=m['boundsInPointsBitmapOrder'];dimensions.append('none' if r is None else f"{r['width']:.2f}×{r['height']:.2f}"+(' (edge)' if m['touchesCropEdge'] else ''))
        fonts={f['reference']:f['pointSize'] for f in row['referenceFonts']}
        crop=row['files']['crop']['path']
        lines.append(f"| {row['size']} | {row['label']} | {dimensions[0]} | {dimensions[1]} | {row['percentileContrastEstimate']:.3f}:1 | {fonts['body']:.2f} / {fonts['body-size-monospaced-digits']:.2f} | [crop](<{crop}>) |")
    return '\n'.join(lines)+'\n'

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--attachments',required=True);parser.add_argument('--output',required=True);parser.add_argument('--completed-export',action='store_true',required=True,help='Operator attests export is complete and original native action terminal')
    args=parser.parse_args();summary=inspect_export(args.attachments);out=Path(args.output).absolute()
    require(not out.exists(),'Output must be fresh');require(all(not p.endswith('.xcresult') for p in out.parts),'xcresult output forbidden')
    input_path=Path(args.attachments).absolute();require(input_path not in out.parents,'Output cannot be within input export')
    out.mkdir(parents=True)
    (out/'summary.json').write_text(json.dumps(summary,indent=2,allow_nan=False)+'\n')
    (out/'measurements.md').write_text(table(summary))
    print(json.dumps({'status':summary['status'],'groups':21,'output':str(out),'acceptance':'not assessed'}))

if __name__=='__main__':
    try: main()
    except (ValueError,KeyError,TypeError,OSError,json.JSONDecodeError) as error:
        raise SystemExit('REFUSED: '+str(error))
