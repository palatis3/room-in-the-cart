import { createRuntime } from './runtime.js';
const runtime = await createRuntime();
const {server} = runtime;
server.listen(Number(process.env.PORT ?? 3001), process.env.HOST ?? '127.0.0.1');
for (const signal of ['SIGTERM', 'SIGINT'] as const) {
  process.on(signal, () => server.close(() => { void runtime.close(); }));
}
