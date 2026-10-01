import { defineConfig } from 'vitest/config'

// Node by default; tests that mount React opt in with
// `// @vitest-environment jsdom` at the top of the file.
export default defineConfig({
  esbuild: { jsx: 'automatic' },
  test: {
    environment: 'node',
    include: ['src/**/*.test.{ts,tsx}'],
  },
})
