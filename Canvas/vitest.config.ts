import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vitest/config'

const here = path.dirname(fileURLToPath(import.meta.url))

export default defineConfig({
  resolve: { alias: { '@': path.resolve(here, 'src') } },
  test: {
    environment: 'node',
    execArgv: ['--disable-warning=ExperimentalWarning'],
    include: ['src/**/__tests__/**/*.test.{ts,tsx}'],
  },
})
