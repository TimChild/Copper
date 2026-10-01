import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react-swc'

/**
 * Built into the Copper bundle folder, which SwiftPM copies as a resource
 * and the `copper-easel://` scheme handler serves (`/<id>` → index.html,
 * `/assets/<file>` → assets/). Nothing is fetched from the network at runtime.
 */
export default defineConfig({
  plugins: [react()],
  base: '/',
  server: {
    host: '127.0.0.1',
    port: 5291,
    strictPort: true,
  },
  preview: {
    host: '127.0.0.1',
    port: 5292,
    strictPort: true,
  },
  build: {
    outDir: '../Sources/Search/Fork/Easel/web',
    emptyOutDir: true,
    assetsDir: 'assets',
    sourcemap: false,
    // One page, one chunk: the scheme handler serves a folder, not a CDN,
    // so there is nothing to gain from cache-splitting vendors.
    rollupOptions: { output: { manualChunks: undefined } },
    chunkSizeWarningLimit: 1600,
  },
})
