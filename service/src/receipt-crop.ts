import { crc32, deflateSync } from 'node:zlib';
import { z } from 'zod';

// A crop contains only one grayscale byte per pixel, never an original file or its metadata.
export const receiptCrop = z.object({
  width:z.int().min(8).max(768), height:z.int().min(8).max(240), pixels:z.string().max(245760)
}).strict().refine(value => {
  const bytes = value.width * value.height;
  if (value.pixels.length !== Math.ceil(bytes / 3) * 4) return false;
  const decoded = Buffer.from(value.pixels,'base64');
  return decoded.length === bytes && decoded.toString('base64') === value.pixels;
});

export function receiptCropURL(crop: z.infer<typeof receiptCrop>): string {
  const raw = Buffer.from(crop.pixels,'base64');
  const rows = Buffer.alloc((crop.width + 1) * crop.height);
  for (let y = 0; y < crop.height; y++) {
    raw.copy(rows,y * (crop.width + 1) + 1,y * crop.width,(y + 1) * crop.width);
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(crop.width); header.writeUInt32BE(crop.height,4); header[8] = 8;
  function chunk(type: string, data: Buffer) {
    const output = Buffer.alloc(12 + data.length);
    output.writeUInt32BE(data.length); output.write(type,4,4,'ascii'); data.copy(output,8);
    output.writeUInt32BE(crc32(output.subarray(4,8 + data.length)),8 + data.length);
    return output;
  }
  const png = Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]),chunk('IHDR',header),
    chunk('IDAT',deflateSync(rows)),chunk('IEND',Buffer.alloc(0))]);
  return 'data:image/png;base64,' + png.toString('base64');
}
