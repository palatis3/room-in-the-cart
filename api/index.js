import { createRuntime } from '../service/dist/runtime.js';

// Export the same Node HTTP server used by local integration tests. Vercel owns
// the listener; this entry point never opens another port or buffers request bodies.
const { server } = await createRuntime();
export default server;
