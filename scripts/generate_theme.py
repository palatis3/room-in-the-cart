#!/usr/bin/env python3
"""Generate native and web semantic tokens from the accepted Foundation contract."""
import json, pathlib, sys
root = pathlib.Path(__file__).resolve().parents[1]
tokens = json.loads((root / 'shared/contracts/theme.json').read_text())
outputs = {}
for name in tokens['light']:
    colors = []
    for mode in ('light', 'dark'):
        value = tokens[mode][name].lstrip('#')
        color = {'idiom':'universal','color':{'color-space':'srgb','components':dict(zip(('red','green','blue'), ('0x'+value[i:i+2] for i in (0,2,4)))) | {'alpha':'1.000'}}}
        if mode == 'dark': color['appearances'] = [{'appearance':'luminosity','value':'dark'}]
        colors.append(color)
    outputs[f'ios/Resources/Assets.xcassets/{name}.colorset/Contents.json'] = json.dumps({'colors':colors,'info':{'author':'xcode','version':1}}, indent=2)+'\n'
outputs['ios/Resources/Assets.xcassets/Contents.json'] = json.dumps({'info':{'author':'xcode','version':1}},indent=2)+'\n'
outputs['web/src/theme.css'] = '\n'.join(selector+' {\n'+ '\n'.join(f'  --{k.replace("_","-")}: {v};' for k,v in tokens[mode].items())+'\n}' for selector,mode in [(':root','light'),('@media (prefers-color-scheme: dark) { :root','dark')])+'\n}\n'
for name, content in outputs.items():
    path = root/name
    if '--check' in sys.argv:
        if not path.exists() or path.read_text()!=content: sys.exit('Stale generated token: '+name)
    else:
        path.parent.mkdir(parents=True,exist_ok=True)
        path.write_text(content)
print('Theme tokens verified' if '--check' in sys.argv else 'Theme tokens generated')
