import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { defineConfig, type Plugin } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { viteSingleFile } from 'vite-plugin-singlefile'

const here = path.dirname(fileURLToPath(import.meta.url))

/** The dev server serves `index.html`; the shipped file is `canvas.html`. */
function renameHtml(to: string): Plugin {
  let outDir = 'dist'
  return {
    name: 'copper-canvas-rename-html',
    apply: 'build',
    configResolved(config) {
      outDir = path.resolve(config.root, config.build.outDir)
    },
    closeBundle() {
      const from = path.join(outDir, 'index.html')
      if (fs.existsSync(from)) fs.renameSync(from, path.join(outDir, to))
    },
  }
}

/**
 * The page never talks to the network: the shipped build allows no
 * connections at all (the host relays the sync socket over the bridge). Dev
 * keeps a socket open for hot reload. Images may come from https URLs.
 */
function csp(): Plugin {
  const policy = (dev: boolean) =>
    [
      "default-src 'none'",
      `script-src ${dev ? "'self' 'unsafe-inline'" : "'unsafe-inline'"}`,
      "style-src 'self' 'unsafe-inline'",
      'img-src data: blob: https: http:',
      `connect-src ${dev ? "'self' ws: wss:" : "'none'"}`,
      'font-src data:',
      "base-uri 'none'",
      "form-action 'none'",
    ].join('; ')
  let dev = true
  return {
    name: 'copper-canvas-csp',
    configResolved(config) {
      dev = config.command === 'serve'
    },
    transformIndexHtml(html) {
      return html.replace('__CANVAS_CSP__', policy(dev))
    },
  }
}

/**
 * One self-contained `dist/canvas.html`: every script, style and asset is
 * inlined, so the host can load it from the app bundle with no network.
 */
export default defineConfig({
  plugins: [
    react(),
    tailwindcss(),
    csp(),
    viteSingleFile({ removeViteModuleLoader: true }),
    renameHtml('canvas.html'),
  ],
  resolve: { alias: { '@': path.resolve(here, 'src') } },
  build: {
    target: 'safari16',
    outDir: 'dist',
    emptyOutDir: true,
    assetsInlineLimit: 100_000_000,
    cssCodeSplit: false,
    reportCompressedSize: false,
  },
  server: { port: 5173, strictPort: false },
})
