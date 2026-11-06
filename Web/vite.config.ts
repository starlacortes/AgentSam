import { defineConfig } from 'vitest/config'
import react from '@vitejs/plugin-react'

// In development, run the Swift server on :8080 with AGENTSAM_INSECURE_COOKIES=1
// and `npm run dev` here; Vite proxies /api (including WebSockets) to it.
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      '/api': { target: 'http://127.0.0.1:8080', ws: true, changeOrigin: false },
    },
  },
  build: {
    outDir: 'dist',
    sourcemap: false,
    // No inline scripts or styles injected by the build, to keep the CSP strict.
    assetsInlineLimit: 0,
  },
  test: {
    environment: 'jsdom',
    globals: false,
  },
})
