"""Synthetic parser controls only; not native/rendered measurement evidence."""
import copy,importlib.util,json,struct,tempfile,unittest,zlib
from pathlib import Path
spec=importlib.util.spec_from_file_location('summary',Path(__file__).with_name('summarize_measurements.py'))
summary=importlib.util.module_from_spec(spec);spec.loader.exec_module(summary)

def png():
    def chunk(kind,data):return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',10,10,8,2,0,0,0))+chunk(b'IDAT',zlib.compress((b'\x00'+b'\xff'*30)*10))+chunk(b'IEND',b'')

def setup_export(root):
    manifest=[];n=0
    for size,suffix in [('small','Small'),('large','Large'),('ax5','AX5')]:
        test={'testIdentifier':summary.METHOD+suffix+'()','attachments':[]};manifest.append(test)
        for key,(label,owner,identifier) in summary.TARGETS.items():
            r={'x':0,'y':0,'width':10,'height':10}
            fonts=[{'reference':f,'fontName':'synthetic-reference','pointSize':17,'lineHeight':20,'capHeight':12,'xHeight':8,'ascender':15,'descender':-5,'textBounds':r} for f in summary.FONTS]
            m={'schema':1,'size':size,'key':key,'label':label,'ownerLabel':owner,'ownerIdentifier':identifier,'requestedCategory':'UICTContentSizeCategory'+summary.SIZES[size],'launchArgument':'UICTContentSizeCategory'+summary.SIZES[size],'hittable':True,'enabled':True,'ownerFrame':r,'targetFrame':r,'readingViewport':r,'dragArea':r,'cropWidthPixels':10,'cropHeightPixels':10,'pixelsPerPointX':1,'pixelsPerPointY':1,'referenceFonts':fonts,'pixels':{'colorSpace':'sRGB','layout':'32-bit big-endian RGBX','cropLuminanceP01':0,'cropLuminanceP99':1,'percentileContrastEstimate':21,'inkCandidates':[{'absoluteLinearLuminanceDelta':d,'pixelCount':1,'boundsInBitmapPixels':{'x':2,'y':3,'width':1,'height':1},'touchesCropEdge':False} for d in (.1,.2)]}}
            for kind in sorted(summary.KINDS):
                n+=1;ext='png' if kind in ('crop','screen') else 'txt';filename=f'{n}.{ext}';human_kind='metrics.json' if kind=='metrics' else kind
                name=f'S24-measure-{size}-{key}-{human_kind}_0_00000000-0000-0000-0000-000000000001.{ext}'
                (root/filename).write_bytes(png() if ext=='png' else (json.dumps(m).encode() if kind=='metrics' else b'OWNER\nsynthetic\nTARGET\nsynthetic'))
                test['attachments'].append({'suggestedHumanReadableName':name,'exportedFileName':filename,'deviceId':'synthetic','deviceName':'synthetic','configurationName':'synthetic','timestamp':1})
    (root/'manifest.json').write_text(json.dumps(manifest));return manifest

class Controls(unittest.TestCase):
    def setUp(self):self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name).resolve();self.manifest=setup_export(self.root)
    def tearDown(self):self.tmp.cleanup()
    def write_manifest(self): (self.root/'manifest.json').write_text(json.dumps(self.manifest))
    def metric(self):
        a=next(a for a in self.manifest[0]['attachments'] if '-metrics.json' in a['suggestedHumanReadableName']);p=self.root/a['exportedFileName'];return p,json.loads(p.read_text())
    def test_complete_synthetic_inventory_is_not_acceptance(self):
        s=summary.inspect_export(self.root);self.assertEqual(s['observedGroups'],21);self.assertEqual(s['acceptance'],'not assessed');self.assertEqual(s['measurements'][0]['inkCandidates'][0]['boundsInPointsBitmapOrder']['height'],1);self.assertIn('No test, font-scaling',summary.table(s))
    def test_missing_attachment_rejected(self):
        self.manifest[0]['attachments'].pop();self.write_manifest()
        with self.assertRaisesRegex(ValueError,'Missing/unexpected'):summary.inspect_export(self.root)
    def test_duplicate_identity_rejected(self):
        self.manifest[0]['attachments'].append(copy.deepcopy(self.manifest[0]['attachments'][0]));self.write_manifest()
        with self.assertRaisesRegex(ValueError,'Duplicate measurement'):summary.inspect_export(self.root)
    def test_wrong_label_rejected(self):
        p,m=self.metric();m['label']='$99.99';p.write_text(json.dumps(m))
        with self.assertRaisesRegex(ValueError,'Mismatched metadata label'):summary.inspect_export(self.root)
    def test_wrong_selector_rejected(self):
        self.manifest[0]['testIdentifier']=summary.METHOD+'AX5()';self.write_manifest()
        with self.assertRaisesRegex(ValueError,'Wrong test identity'):summary.inspect_export(self.root)
    def test_wrong_scale_rejected(self):
        p,m=self.metric();m['pixelsPerPointX']=2;p.write_text(json.dumps(m))
        with self.assertRaisesRegex(ValueError,'normalization'):summary.inspect_export(self.root)
    def test_traversal_rejected(self):
        self.manifest[0]['attachments'][0]['exportedFileName']='../outside.txt';self.write_manifest()
        with self.assertRaisesRegex(ValueError,'Unsafe exported'):summary.inspect_export(self.root)
    def test_duplicate_json_key_rejected(self):
        p,m=self.metric();p.write_text(json.dumps(m)[:-1]+',"key":"after"}')
        with self.assertRaisesRegex(ValueError,'Duplicate JSON key'):summary.inspect_export(self.root)

if __name__=='__main__':unittest.main()
