import { z } from 'zod';
import { ServiceError } from './errors.js';
import type { AssistanceBudget } from './receipt-assistance.js';

// Mono 16-bit little-endian PCM, 16 kHz. The fixed layout bounds both duration and cost.
const maximumSamples = 30 * 16_000;
export const voiceAssistanceInput = z.object({
  version:z.literal(1), requestID:z.uuid(), issuedAt:z.int().positive(), consent:z.literal(true),
  language:z.enum(['en','es']), samples:z.int().min(1600).max(maximumSamples),
  pcm:z.string().min(1).max(maximumSamples * 2 * 4 / 3)
}).strict().refine(value => {
  if (value.pcm.length !== 4 * Math.ceil(value.samples * 2 / 3)) return false;
  const decoded = Buffer.from(value.pcm,'base64');
  return decoded.length === 2 * value.samples && decoded.toString('base64') === value.pcm;
});
type Input = z.infer<typeof voiceAssistanceInput>;
const failure = () => new ServiceError(503,'voice_transcription_unavailable','Continue dictating on your iPhone or type your list.');

function wav(pcm: Buffer) {
  const header = Buffer.alloc(44);
  header.write('RIFF'); header.writeUInt32LE(36 + pcm.length,4); header.write('WAVEfmt ',8);
  header.writeUInt32LE(16,16); header.writeUInt16LE(1,20); header.writeUInt16LE(1,22);
  header.writeUInt32LE(16_000,24); header.writeUInt32LE(32_000,28); header.writeUInt16LE(2,32);
  header.writeUInt16LE(16,34); header.write('data',36); header.writeUInt32LE(pcm.length,40);
  return Buffer.concat([header,pcm]);
}

export class VoiceAssistance {
  constructor(readonly maximumCost: number, private readonly model: string, private readonly key: string,
              private readonly transport: typeof fetch = fetch) {}

  static configured(env: NodeJS.ProcessEnv,budget?: AssistanceBudget): VoiceAssistance | undefined {
    if (!budget || env.VOICE_ASSISTANCE_ENABLED !== 'true') return;
    const model = env.VOICE_ASSISTANCE_MODEL;
    const key = env.RECEIPT_ASSISTANCE_API_KEY;
    const cost = Number(env.VOICE_ASSISTANCE_MAX_REQUEST_USD_MICROS);
    if (!key || !model || !/^[a-zA-Z0-9._-]{1,100}$/.test(model) || !Number.isSafeInteger(cost) || cost < 1 || cost > budget.dailyMicros) return;
    return new VoiceAssistance(cost,model,key);
  }

  async transcribe(input: Input, cancellation: AbortSignal) {
    const signal = AbortSignal.any([cancellation,AbortSignal.timeout(15_000)]);
    try {
      signal.throwIfAborted();
      const form = new FormData();
      form.append('model',this.model);
      form.append('language',input.language);
      form.append('response_format','json');
      form.append('file',new Blob([wav(Buffer.from(input.pcm,'base64'))],{type:'audio/wav'}),'list.wav');
      const response = await this.transport('https://api.openai.com/v1/audio/transcriptions',{
        method:'POST',headers:{Authorization:'Bearer '+this.key},redirect:'error',signal,body:form
      });
      if (!response.ok || !response.body) { await response.body?.cancel(); throw failure(); }
      const reader = response.body.getReader();
      const chunks: Uint8Array[] = [];
      let bytes = 0;
      for (;;) {
        const {value,done} = await reader.read();
        if (done) break;
        bytes += value.length;
        if (bytes > 16_384) { await reader.cancel(); throw failure(); }
        chunks.push(value);
      }
      signal.throwIfAborted();
      const value: unknown = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      const {text} = z.object({text:z.string().trim().min(1).max(4096)
        .refine(s=>Buffer.byteLength(s)<=8192 && !/[\u0000-\u0009\u000b-\u001f\u007f]/u.test(s) && s.split('\n').length<=100)}).parse(value);
      return {version:1,requestID:input.requestID,language:input.language,text};
    } catch { throw failure(); }
  }
}
