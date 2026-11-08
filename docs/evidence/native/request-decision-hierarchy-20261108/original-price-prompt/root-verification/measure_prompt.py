from pathlib import Path
import struct,zlib,hashlib,json,collections
R=Path('.build/S24DecisionHierarchyNov08/price-prompt-root-review');p=Path('.build/S24DecisionHierarchyNov08/light-run/captures/png-3-0/434F6C14-31BF-4639-838D-25A4691710B2.png');raw=p.read_bytes();assert raw[:8]==b'\x89PNG\r\n\x1a\n'
o=8;chunks=[];idat=[];srgb=False
while o<len(raw):
 n=struct.unpack('>I',raw[o:o+4])[0];kind=raw[o+4:o+8];b=raw[o+8:o+8+n];crc=struct.unpack('>I',raw[o+8+n:o+12+n])[0];assert zlib.crc32(kind+b)&0xffffffff==crc
 chunks.append({'type':kind.decode(),'bytes':n})
 if kind==b'IHDR':w,h,depth,color,compression,filter_,interlace=struct.unpack('>IIBBBBB',b);assert (depth,color,compression,filter_,interlace)==(8,2,0,0,0)
 if kind==b'IDAT':idat.append(b)
 if kind==b'sRGB':srgb=True;intent=b[0]
 o+=n+12
assert srgb
packed=zlib.decompress(b''.join(idat));stride=w*3;assert len(packed)==h*(stride+1)
rows=[];prev=bytearray(stride)
def paeth(a,b,c):
 q=a+b-c;pa,pb,pc=abs(q-a),abs(q-b),abs(q-c)
 return a if pa<=pb and pa<=pc else b if pb<=pc else c
for y in range(h):
 at=y*(stride+1);f=packed[at];row=bytearray(packed[at+1:at+1+stride]);assert f in range(5)
 for x in range(stride):
  left=row[x-3] if x>=3 else 0;up=prev[x];ul=prev[x-3] if x>=3 else 0
  if f==1:row[x]=(row[x]+left)&255
  elif f==2:row[x]=(row[x]+up)&255
  elif f==3:row[x]=(row[x]+((left+up)//2))&255
  elif f==4:row[x]=(row[x]+paeth(left,up,ul))&255
 rows.append(row);prev=row
# Bound by the visually identified price row, between its two horizontal separators.
# Use original PNG pixels, not the display's resized preview; this ROI excludes separators and adjacent rows.
roi=(90,1040,1060,1145)
def pixels(box):
 x0,y0,x1,y1=box
 for y in range(y0,y1):
  for x in range(x0,x1):yield x,y,tuple(rows[y][x*3:x*3+3])
def lum(rgb):
 def linear(x):
  v=x/255;return v/12.92 if v<=.04045 else ((v+.055)/1.055)**2.4
 r,g,b=map(linear,rgb);return .2126*r+.7152*g+.0722*b
def contrast(a,b):
 la,lb=lum(a),lum(b);return (max(la,lb)+.05)/(min(la,lb)+.05)
counts=collections.Counter(c for x,y,c in pixels(roi));background=counts.most_common(1)[0][0]
ink=[(x,y,c) for x,y,c in pixels(roi) if min(c)<250];glyphCounts=collections.Counter(c for x,y,c in ink)
xs=[x for x,y,c in ink];ys=[y for x,y,c in ink];bbox=[min(xs),min(ys),max(xs)+1,max(ys)+1]
darkest=min(glyphCounts,key=lum);dominant=glyphCounts.most_common(1)[0][0]
rowcounts=collections.Counter(y for x,y,c in ink)
report={'sourcePNG':str(p),'sourceSHA256':hashlib.sha256(raw).hexdigest(),'dimensions':[w,h],'PNGColorType':'RGB8','sRGBChunk':True,'renderingIntent':intent,'PNGChunkCRCsVerified':True,'roiPixelsLeftTopRightBottomExclusive':roi,'glyphThreshold':'min(R,G,B)<250','glyphBoundingBoxPixels':bbox,'glyphBoundingBoxPointsAt3x':[n/3 for n in bbox],'backgroundRGB':background,'backgroundCountInROI':counts[background],'ROIPixelCount':sum(counts.values()),'glyphPixelCount':len(ink),'dominantNonBackgroundRGB':dominant,'dominantGlyphCount':glyphCounts[dominant],'darkestGlyphRGB':darkest,'darkestGlyphCount':glyphCounts[darkest],'dominantRenderedContrast':contrast(dominant,background),'maximumObservedRenderedContrast':contrast(darkest,background),'requiredContrast':4.5,'glyphHistogramTop20':[{'RGB':c,'count':n,'contrast':contrast(c,background)} for c,n in glyphCounts.most_common(20)],'nonwhiteRows':dict(sorted(rowcounts.items())),'limits':['Single retained light/standard-text screenshot; not dark, AX5, increased-contrast or physical display validation.','Rendered pixel contrast, not recovered pre-alpha style token.','Antialias edge pixels trend toward background; reported dominant darkest core and darkest-pixel upper bound avoid selecting only pale edges.','Glyph bounding box is inferred from pixels/source label, not an accessibility element frame.','No screenshot modification, native execution or canonical-source edit.']}
(R/'measurement.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k not in ['glyphHistogramTop20','nonwhiteRows','limits']},indent=2))
