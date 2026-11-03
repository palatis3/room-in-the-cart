import { defineConfig } from 'vite';

// The browser always calls its own origin. This development-only proxy targets
// the actual local service; production serves /v1 through its HTTPS reverse proxy.
export default defineConfig({
  build: { outDir: 'public-build', emptyOutDir: true },
  server: { proxy: { '/v1': { target: process.env.RITC_SERVICE_ORIGIN ?? 'http://127.0.0.1:3001', changeOrigin: false } } }
});
